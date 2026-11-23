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

    /// The command lines that copy each entry: a symbolic link at the root
    /// as a link (`cp -P -p`: ditto follows a link it's given), anything
    /// else with `ditto` (owners as the person may keep them, modes, ACLs,
    /// extended attributes; a link inside a folder stays a link).
    public static func commands(from source: String, to destination: String, entries: [String],
                                isLink: (String) -> Bool) -> [[String]] {
        entries.map { name in
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destination as NSString).appendingPathComponent(name)
            return isLink(from) ? [cp, "-P", "-p", from, to] : [ditto, from, to]
        }
    }

    /// Whether a path is a symbolic link itself (not followed).
    public static func isLink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Copies `source` (a role's volume, its mount point) onto
    /// `destination` (its staged copy), checks both sides' manifests are
    /// identical and that the source didn't change meanwhile, and writes
    /// the marker at `destination`'s root; the marker. A marker already
    /// there is removed first. A destination holding anything (but the
    /// system's folders) is refused unless `replace`, which empties it
    /// first. On any failure there's no marker, and the error says what.
    @discardableResult
    public static func copyAndVerify(role: VolumeRole, from source: String, to destination: String, sourceUUID: String, newUUID: String,
                                     replace: Bool = false, now: () -> Date = Date.init,
                                     run: ([String]) throws -> Void, say: (String) -> Void = { _ in }) throws -> ConversionMarker {
        let files = FileManager.default
        let marker = ConversionMarker.path(atRoot: destination)
        if files.fileExists(atPath: marker) || isLink(marker) {
            try files.removeItem(atPath: marker)
            say("removed the old marker at \(marker)")
        }
        let there = try entries(at: destination)
        if !there.isEmpty {
            guard replace else {
                throw DiskVolumesError.blocked("\(destination) holds \(there.count) entries already (\(there.prefix(3).joined(separator: ", "))…): "
                    + "a copy goes onto an empty volume. Run again with --replace to empty it first.")
            }
            for name in there { try files.removeItem(atPath: (destination as NSString).appendingPathComponent(name)) }
            say("emptied \(destination) (\(there.count) entries)")
        }
        let before = try VolumeManifest.make(of: source, .listing)
        let commands = commands(from: source, to: destination, entries: try entries(at: source), isLink: isLink)
        for command in commands {
            say("copying: " + command.joined(separator: " "))
            do {
                try run(command)
            } catch {
                throw DiskVolumesError.failed("The copy failed at \(command.joined(separator: " ")): \(error). No marker was written; nothing was swapped.")
            }
        }
        say("checking: every file's sha256 and every link's target, on both sides")
        let original = try VolumeManifest.make(of: source, .content)
        let copy = try VolumeManifest.make(of: destination, .content)
        guard original.lines == copy.lines else {
            let differences = original.differences(from: copy)
            throw DiskVolumesError.failed("MISMATCH: \(destination) isn't what \(source) holds (- only in the source, + only in the copy):\n  "
                + differences.joined(separator: "\n  ") + "\nNo marker was written; nothing was swapped.")
        }
        let after = try VolumeManifest.make(of: source, .listing)
        guard before == after else {
            let differences = before.differences(from: after)
            throw DiskVolumesError.failed("\(source) changed while it was copied (- before, + after):\n  "
                + differences.joined(separator: "\n  ") + "\nStop whatever writes there, then run copy-staged again. No marker was written.")
        }
        if !original.sockets.isEmpty {
            say("left out \(original.sockets.count) socket files (no data): \(original.sockets.prefix(5).joined(separator: ", "))")
        }
        let verified = ConversionMarker(role: role, sourceUUID: sourceUUID, newUUID: newUUID, files: original.files, links: original.links,
                                        directories: original.directories, manifestSHA256: original.sha256,
                                        sourceListingSHA256: after.sha256, verified: now())
        try verified.write(atRoot: destination)
        say("wrote \(marker): \(verified.summary)")
        return verified
    }
}
