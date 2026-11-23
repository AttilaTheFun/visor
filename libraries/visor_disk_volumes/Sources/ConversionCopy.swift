// copy-staged: a role's volume copied onto its staged case-sensitive copy
// as the person (never root), checked file by file, and the marker left
// that Swap In asks for. Nothing is run here but through `run`, the
// caller's (Visor Disk Utility's, or a test's).

import Foundation

public enum ConversionCopy {
    /// ditto and cp, by their full paths.
    public static let ditto = "/usr/bin/ditto"
    public static let cp = "/bin/cp"

    /// The entries at a volume's root to copy: all but the system's
    /// folders and the marker, sorted.
    public static func entries(at root: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: root)
                .filter { !VolumeManifest.leftOutAtRoot.contains($0) }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        } catch {
            throw DiskVolumesError.failed("\(root) couldn't be read: \(error.localizedDescription)")
        }
    }

    /// chflags, by its full path.
    public static let chflags = "/usr/bin/chflags"

    /// The command lines that copy each entry: a symbolic link at the root
    /// as a link (`cp -P -p`: ditto follows a link it's given), anything
    /// else with `ditto` (owners as the person may keep them, modes, ACLs,
    /// extended attributes, flags; a link inside a folder stays a link).
    /// ditto leaves off the flags of the folder it's given itself (hidden,
    /// say), so a folder at the root with any gets them after, by
    /// `chflags <octal>`.
    public static func commands(from source: String, to destination: String, entries: [String],
                                inspector: some FileInspecting) throws -> [[String]] {
        try entries.flatMap { name -> [[String]] in
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            let file = try inspector.inspect(from)
            if file.kind == .link { return [[cp, "-P", "-p", from, to]] }
            let flags = file.flags & FileInspection.userFlags
            guard file.kind == .directory, flags != 0 else { return [[ditto, from, to]] }
            return [[ditto, from, to], [chflags, "0" + String(flags, radix: 8), to]]
        }
    }

    /// Whether a path is a symbolic link itself (not followed).
    public static func isLink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// What stops a copy as the person keeping every file as it is: a
    /// file or folder of another owner (ditto as the person makes it
    /// theirs), of a group the person isn't in, that they can't read, whose
    /// extended attributes or ACL can't be read (so neither side's could be
    /// compared), with a flag only root can set, or whose data isn't here (dataless); and a
    /// hard link shared between two entries at the root (each entry is
    /// copied on its own, so the link would be split). A line each, at most
    /// `limit`, and how many there are in all.
    public static func obstacles(at root: String, owner: FileOwner, inspector: some FileInspecting,
                                 limit: Int = 40) throws -> (lines: [String], count: Int) {
        var lines: [String] = []
        var count = 0
        func note(_ line: String) {
            count += 1
            if lines.count < limit { lines.append(line) }
        }
        // Each shared inode: the root entry it was first seen under.
        var entryOf: [UInt64: (entry: String, path: String)] = [:]
        try VolumeTree.walk(root, inspector: inspector, failed: { path, _ in note("\(path): its metadata can't be read") }) { path, file in
            if file.kind == .socket { return false }
            if file.uid != owner.uid { note("\(path): owned by uid \(file.uid), not \(owner.uid)") }
            if file.kind != .link, !owner.groups.contains(file.gid) { note("\(path): group \(file.gid), not one of yours") }
            if file.kind != .link, !file.readable { note("\(path): you can't read it") }
            if file.kind != .link, file.xattrs == FileInspection.unreadable { note("\(path): its extended attributes can't be read") }
            if file.kind != .link, file.acl == FileInspection.unreadable { note("\(path): its ACL can't be read") }
            if file.flags & FileInspection.systemFlags != 0 {
                note("\(path): flags only root can set (0x\(String(file.flags & FileInspection.systemFlags, radix: 16)))")
            }
            if file.flags & FileInspection.datalessFlag != 0 { note("\(path): its data isn't on this Mac (dataless)") }
            if file.kind == .regular, file.linkCount > 1 {
                let entry = String(path.prefix { $0 != "/" })
                if let first = entryOf[file.inode] {
                    if first.entry != entry { note("\(path): a hard link to \(first.path), in another entry at the root") }
                } else {
                    entryOf[file.inode] = (entry, path)
                }
            }
            return true
        }
        return (lines, count)
    }

    /// The bytes the copy writes: each regular file's and folder's
    /// allocated size (its blocks, so a tree of small files, node_modules
    /// or .git's objects, is counted as it takes the disk, not by its
    /// bytes), a file shared by hard links within one root entry once
    /// (ditto keeps those), a clone in full (a copy doesn't share its
    /// blocks).
    public static func bytesNeeded(at root: String, inspector: some FileInspecting) throws -> Int64 {
        var total: Int64 = 0
        var seen: Set<String> = []
        try VolumeTree.walk(root, inspector: inspector) { path, file in
            guard file.kind == .regular || file.kind == .directory else { return true }
            if file.kind == .regular, file.linkCount > 1 {
                let key = String(path.prefix { $0 != "/" }) + "\u{0}\(file.inode)"
                guard seen.insert(key).inserted else { return true }
            }
            total += file.allocated
            return true
        }
        return total
    }

    /// The folders of the system's at a volume's root, which aren't copied:
    /// a line saying so, when there are any (how many entries each holds,
    /// where the person may look).
    public static func leftOut(at root: String) -> String? {
        let files = FileManager.default
        let present = VolumeManifest.systemFolders.sorted().filter { files.fileExists(atPath: (root as NSString).appendingPathComponent($0)) }
        guard !present.isEmpty else { return nil }
        let described = present.map { name -> String in
            let count = (try? files.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(name)))?.count
            return count.map { "\(name) (\($0) entries)" } ?? "\(name) (unreadable)"
        }
        return "left out of the copy, as the system's own: " + described.joined(separator: ", ")
            + ". The volume's Trash (.Trashes) and temporary items (.TemporaryItems) aren't carried over: empty or move out anything you want first."
    }

    /// Links that resolve on the source but not on the copy: a relative
    /// target that named a file in another case, which a case-insensitive
    /// volume found and a case-sensitive one doesn't.
    public static func caseDependentLinks(source: String, copy: String, inspector: some FileInspecting) throws -> [String] {
        let files = FileManager.default
        var found: [String] = []
        try VolumeTree.walk(source, inspector: inspector) { path, file in
            if file.kind == .link, let target = file.linkTarget, !target.hasPrefix("/"),
               files.fileExists(atPath: (source as NSString).appendingPathComponent(path)),
               !files.fileExists(atPath: (copy as NSString).appendingPathComponent(path)) {
                found.append(path)
            }
            return true
        }
        return found
    }

    /// Copies `source` (a role's volume, its mount point) onto
    /// `destination` (its staged copy), as `owner`, and checks it: first,
    /// that nothing on the source can't be copied as it is by the person
    /// (`obstacles`: refused, with the list) and that the copy fits
    /// (`destinationFree`, its bytes free, `keepFree` of them left over);
    /// then the copy; then both
    /// sides' manifests identical (data, mode, owner, group, flags,
    /// extended attributes, ACLs, hard links) and the source unchanged
    /// meanwhile (its listing, before and after). Only then the marker,
    /// written at `destination`'s root; the marker. A marker already there
    /// is removed first. A destination holding anything (but the system's
    /// folders) is refused unless `replace`, which empties it first. On any
    /// failure there's no marker, and the error says what.
    @discardableResult
    public static func copyAndVerify(role: VolumeRole, from source: String, to destination: String, sourceUUID: String, newUUID: String,
                                     owner: FileOwner, inspector: some FileInspecting = FoundationFileInspector(),
                                     destinationFree: Int64? = nil, keepFree: Int64 = 0, replace: Bool = false, now: () -> Date = Date.init,
                                     run: ([String]) throws -> Void, say: (String) -> Void = { _ in }) throws -> ConversionMarker {
        let files = FileManager.default
        let marker = ConversionMarker.path(atRoot: destination)
        if files.fileExists(atPath: marker) || isLink(marker) {
            try files.removeItem(atPath: marker)
            say("removed the old marker at \(marker)")
        }
        let obstacles = try obstacles(at: source, owner: owner, inspector: inspector)
        guard obstacles.count == 0 else {
            throw DiskVolumesError.blocked("\(source) holds \(obstacles.count) things the person can't copy as they are "
                + "(copy-staged runs as you, never root):\n  " + obstacles.lines.joined(separator: "\n  ")
                + (obstacles.count > obstacles.lines.count ? "\n  …and \(obstacles.count - obstacles.lines.count) more" : "")
                + "\nGive them to you (sudo chown -R <you>:staff <path>, chflags), or move them off the volume, then run copy-staged again. "
                + "Nothing was copied.")
        }
        let there = try entries(at: destination)
        if !there.isEmpty {
            guard replace else {
                let listed = there.prefix(3).joined(separator: ", ") + (there.count > 3 ? ", …" : "")
                throw DiskVolumesError.blocked("\(destination) holds \(there.count) entries already (\(listed)): "
                    + "a copy goes onto an empty volume. Run again with --replace to empty it first.")
            }
            for name in there { try files.removeItem(atPath: (destination as NSString).appendingPathComponent(name)) }
            say("emptied \(destination) (\(there.count) entries)")
        }
        if let destinationFree {
            let needed = try bytesNeeded(at: source, inspector: inspector)
            // A little room for the folders' own blocks and the marker, and
            // what must stay free beside it (`keepFree`: a copy with no
            // quota shares the container's free space with the system).
            let margin = max(Int64(100_000_000), needed / 50)
            guard needed + margin + keepFree <= destinationFree else {
                let kept = keepFree > 0 ? ", leaving \(ByteSize.describe(keepFree)) free for the rest of the Mac," : ""
                throw DiskVolumesError.blocked("The copy needs about \(ByteSize.describe(needed + margin)) (clones copied in full)\(kept) "
                    + "and \(destination) has \(ByteSize.describe(destinationFree)) free. Nothing was copied.")
            }
        }
        if let line = leftOut(at: source) { say(line) }
        let before = try VolumeManifest.make(of: source, .listing, inspector: inspector)
        let commands = try commands(from: source, to: destination, entries: try entries(at: source), inspector: inspector)
        for command in commands {
            say("copying: " + command.joined(separator: " "))
            do {
                try run(command)
            } catch {
                throw DiskVolumesError.failed("The copy failed at \(command.joined(separator: " ")): \(error). No marker was written; nothing was swapped.")
            }
        }
        say("checking: every file's sha256, mode, owner, group, flags, extended attributes and ACL, every link's target and every hard link, on both sides")
        let original = try VolumeManifest.make(of: source, .content, inspector: inspector)
        let copy = try VolumeManifest.make(of: destination, .content, inspector: inspector)
        guard original.lines == copy.lines else {
            let differences = original.differences(from: copy)
            throw DiskVolumesError.failed("MISMATCH: \(destination) isn't what \(source) holds (- only in the source, + only in the copy):\n  "
                + differences.joined(separator: "\n  ") + "\nNo marker was written; nothing was swapped.")
        }
        let after = try VolumeManifest.make(of: source, .listing, inspector: inspector)
        guard before == after else {
            let differences = before.differences(from: after)
            throw DiskVolumesError.failed("\(source) changed while it was copied (- before, + after):\n  "
                + differences.joined(separator: "\n  ") + "\nStop whatever writes there, then run copy-staged again. No marker was written.")
        }
        if !original.sockets.isEmpty {
            say("left out \(original.sockets.count) socket files (no data): \(original.sockets.prefix(5).joined(separator: ", "))")
        }
        let caseLinks = try caseDependentLinks(source: source, copy: destination, inspector: inspector)
        if !caseLinks.isEmpty {
            say("warning: \(caseLinks.count) links resolve only on a case-insensitive volume (their targets differ in case), "
                + "and won't on the copy: \(caseLinks.prefix(10).joined(separator: ", "))")
        }
        let copyListing = try VolumeManifest.make(of: destination, .listing, inspector: inspector)
        let verified = ConversionMarker(role: role, sourceUUID: sourceUUID, newUUID: newUUID, files: original.files, links: original.links,
                                        directories: original.directories, hardLinks: original.hardLinks.count,
                                        manifestSHA256: original.sha256, sourceListingSHA256: after.sha256,
                                        copyListingSHA256: copyListing.sha256, verified: now())
        try verified.write(atRoot: destination)
        say("wrote \(marker): \(verified.summary)")
        return verified
    }
}
