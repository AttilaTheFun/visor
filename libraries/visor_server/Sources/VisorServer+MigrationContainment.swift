// What a move here takes from the server it comes from, held to where it
// belongs. Peers are only the user's own paired servers, but the offer's
// ids, places and archives are still the other server's words, and a
// server compromised or wrong could name `..`, an absolute path, a `/`
// inside an id, or an archive whose entries lead out. A move takes ids
// only as plain names (SessionPathName: letters, digits, `-` and `_`), the
// conversation's id only as one an agent makes (a UUID), a file only as one
// of the agent's own for that conversation (its place shaped as the agent
// keeps it, or Claude's memory), and no path of the other server's at all:
// every destination is made here, of the agent, the conversation's id and
// the session's new folder (VisorServer+MigrationArrival). It writes
// nothing outside the move's own folder, the agent's place for that
// conversation, the memory of the new folder's project, and that folder;
// and unpacks an archive (the conversation's folder, the memory) only into
// a folder of its own inside where it goes, every entry's name and every
// link it makes checked to stay there, before anything is moved into place.

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Whether `name` (a file's id, the conversation's) is one a move takes
    /// from another server: plain, and not read as an option.
    static func isCarriedName(_ name: String) -> Bool {
        SessionPathName.isPlain(name) && !name.hasPrefix("-")
    }

    /// Where the move's file `id` is kept here: in the move's own folder by
    /// its id; nil for an id that isn't a plain name.
    static func carried(_ id: String, in folder: URL) -> URL? {
        guard isCarriedName(id) else { return nil }
        let url = folder.appendingPathComponent(id, isDirectory: false)
        return SessionPathName.isInside(url, folder) ? url : nil
    }

    /// Whether `path` is a full path with nothing to resolve: absolute, and
    /// no `.`, `..` or empty part (a trailing `/` aside).
    nonisolated static func isPlainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        while parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        if parts == [""] { return true }
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Why the offer (a move's, or a backup's) can't come here as it is:
    /// nil when it can. Each file must be one of the agent's own for the
    /// conversation — at a place shaped as the agent keeps it
    /// (SessionCatalog.destination), or Claude's memory, packed with no
    /// place — and within what a move carries (oversized).
    static func unsafeOffer(_ offer: MigrationOffer) -> String? {
        guard SessionCatalog.isConversationID(offer.resumeID) else {
            return "its conversation's id, “\(offer.resumeID)”, is not one an agent makes"
        }
        guard isPlainPath(offer.session.cwd) else { return "the session's folder, \(offer.session.cwd), is not a full path" }
        var ids: Set<String> = [], places: Set<String> = []
        for file in offer.files {
            guard isCarriedName(file.id), ids.insert(file.id).inserted else { return "it names a file “\(file.id)”" }
            guard places.insert(file.place).inserted else { return "it names a place twice, \(file.place.isEmpty ? "the memory's" : file.place)" }
            if file.place.isEmpty {
                guard file.id == memoryFileID, file.packed, offer.session.agent == .claude else {
                    return "it carries “\(file.id)”, which is not one of the agent's own files for the conversation"
                }
            } else if SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: offer.session.cwd, resume: offer.resumeID) == nil {
                return "it would put a file at \(file.place), which is not where the agent keeps its conversation"
            }
        }
        return oversized(offer.files)
    }

    // MARK: Unpacking

    /// A gzipped tar of the folder `name` (the conversation's folder, the
    /// memory) unpacked into `folder` (made when missing): every entry's
    /// name checked first (never absolute, never through `..`, always under
    /// `name`), and the sizes it declares and its entries held to `limits`
    /// (VisorServer+MigrationUnpackSize); then unpacked into a folder of its
    /// own inside `folder`, measured as it goes and stopped past them,
    /// walked (unsafeTree), and only then moved into place, where nothing
    /// is by that name but an empty folder (never over what is there). What
    /// went wrong, if anything; the folder it was unpacked into goes either
    /// way.
    static func unpack(_ archive: URL, into folder: URL, only name: String, limits: UnpackLimits = UnpackLimits()) async -> String? {
        guard isCarriedName(name) else { return "\(name) is not a name to unpack as" }
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        if let there = try? FileManager.default.attributesOfItem(atPath: destination.path) {
            let empty = (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty == true
            guard there[.type] as? FileAttributeType == .typeDirectory, empty else { return "\(name) is in \(folder.path) already" }
        }
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        // Listed as written (`-P`: no leading `/` taken off), so the names
        // checked are the archive's own.
        guard let listed = await Command.output(tar, ["-t", "-P", "-z", "-f", archive.path]) else { return "tar could not be started" }
        guard listed.status == 0 else { return "it is not an archive tar can read" }
        let names = listed.text.split(separator: "\n").filter { !$0.isEmpty }
        // How many entries it makes, held to the cap before anything else
        // is asked of its names.
        let entries = listedEntries(names, most: limits.entries)
        if let problem = entryRefusal(entries, limits) { return problem }
        for entry in names {
            if let problem = unsafeEntry(String(entry), only: name) { return problem }
        }
        // Each entry's size as it declares it (`-v`), and so all of them,
        // held to the limits before anything is unpacked.
        guard let verbose = await Command.output(tar, ["-t", "-v", "-P", "-z", "--numeric-owner", "-f", archive.path]), verbose.status == 0,
              let declared = listedBytes(verbose.text), declared.entries == names.count else {
            return "the sizes of what it holds could not be read"
        }
        if let problem = unpackRefusal(declared.bytes, limits, in: folder) { return problem }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".visor-unpacking-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard SessionPathName.isInside(staging, folder), (try? files.createDirectory(at: staging, withIntermediateDirectories: false)) != nil else {
            return "could not make a folder to unpack into in \(folder.path)"
        }
        defer { removeTree(staging) }
        let bound = unpackBound(declared.bytes, limits, in: folder)
        let entryLimit = entryBound(entries, limits)
        if let problem = await extract(archive, into: staging, tar: tar, bound: bound, entries: entryLimit, every: limits.every) { return problem }
        let top = ((try? files.contentsOfDirectory(atPath: staging.path)) ?? []).sorted()
        guard top == [name] else { return "it holds \(top.joined(separator: ", ")), not \(name) alone" }
        // The folder itself is the root of the walk: a link in it that
        // leads out of it (to the conversation beside it, say) is refused,
        // not only one that leads out of the unpacking.
        let unpacked = staging.appendingPathComponent(name, isDirectory: true)
        guard (try? files.attributesOfItem(atPath: unpacked.path))?[.type] as? FileAttributeType == .typeDirectory else {
            return "it holds \(name), which is not a folder"
        }
        if let problem = unsafeTree(unpacked) { return problem }
        // Measured once more whole, every folder opened: past a bound
        // between two measures, or in one that couldn't be looked in then.
        // (The unpacking holds that folder alone, so it is that folder and
        // what is in it.)
        let measured = Self.unpacked(staging)
        guard measured.bytes <= bound.bytes else { return bound.why }
        guard measured.entries <= entryLimit.entries else { return entryLimit.why }
        guard SessionPathName.isInside(destination, folder) else { return "\(name) would lead out of \(folder.path)" }
        // The empty folder by that name, the one thing it may take the place of.
        try? files.removeItem(at: destination)
        do { try files.moveItem(at: staging.appendingPathComponent(name, isDirectory: false), to: destination) } catch {
            return "could not put \(name) in \(folder.path): \(error.localizedDescription)"
        }
        return nil
    }

    /// Why an archive's entry (as `tar -t` lists it) can't be unpacked: an
    /// absolute name, one through `..`, or one not under `name`.
    static func unsafeEntry(_ entry: String, only name: String) -> String? {
        guard !entry.hasPrefix("/") else { return "it holds an entry at an absolute path, \(entry)" }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.contains("..") else { return "it holds an entry that leads out, \(entry)" }
        if let first = parts.first, first != name { return "it holds \(entry), not under \(name)" }
        return nil
    }

    /// Why what was unpacked at `root` can't be kept: a link
    /// that leads, followed as the system would, anywhere outside `root`
    /// (an absolute one always); a hard link to a file outside it; anything
    /// but files, folders and links (a device, a fifo, a socket); or a
    /// folder that can't be looked in. Each folder is opened to its owner
    /// (`u+rwx`) before it is listed, so one an archive made unreadable
    /// (0000) or unlistable but passable (0111) is walked like any other,
    /// and one that still can't be listed is a refusal, never taken as
    /// empty.
    static func unsafeTree(_ root: URL) -> String? {
        let files = FileManager.default
        var linked: [NSNumber: Int] = [:]
        var counts: [NSNumber: Int] = [:]
        var folders: [[String]] = [[]]
        while let parts = folders.popLast() {
            let path = ([root.path] + parts).joined(separator: "/")
            let shownFolder = parts.isEmpty ? "the folder itself" : parts.joined(separator: "/")
            openUp(path)
            guard let items = try? files.contentsOfDirectory(atPath: path) else { return "could not look in \(shownFolder)" }
            for item in items {
                let inner = parts + [item]
                let shown = inner.joined(separator: "/")
                guard let attributes = try? files.attributesOfItem(atPath: path + "/" + item),
                      let type = attributes[.type] as? FileAttributeType else { return "could not look at \(shown)" }
                switch type {
                case .typeDirectory: folders.append(inner)
                case .typeSymbolicLink:
                    var hops = 0
                    guard resolved(inner, under: root.path, hops: &hops) != nil else { return "it holds a link that leads out, \(shown)" }
                case .typeRegular:
                    if let count = (attributes[.referenceCount] as? NSNumber)?.intValue, count > 1,
                       let node = attributes[.systemFileNumber] as? NSNumber {
                        linked[node, default: 0] += 1
                        counts[node] = count
                    }
                default: return "it holds \(shown), which is not a file, a folder or a link"
                }
            }
        }
        for (node, seen) in linked where seen < counts[node] ?? 0 { return "it holds a hard link to a file outside it" }
        return nil
    }

    /// The folder at `path` opened to its owner (`u+rwx`), so that it can
    /// be listed, walked through and emptied.
    nonisolated static func openUp(_ path: String) {
        let files = FileManager.default
        guard let mode = (try? files.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber,
              mode.intValue & 0o700 != 0o700 else { return }
        try? files.setAttributes([.posixPermissions: NSNumber(value: mode.intValue | 0o700)], ofItemAtPath: path)
    }

    /// What is at `url` removed, every folder in it opened first (an
    /// archive's folder of mode 0000 can't be emptied as it is).
    nonisolated static func removeTree(_ url: URL) {
        let files = FileManager.default
        var folders = [url.path]
        while let folder = folders.popLast() {
            guard (try? files.attributesOfItem(atPath: folder))?[.type] as? FileAttributeType == .typeDirectory else { continue }
            openUp(folder)
            folders += ((try? files.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
        }
        try? files.removeItem(at: url)
    }

    /// Whether the file at `existing` is the start of the one at `carried`
    /// (the same bytes, as many or fewer): a conversation that has only
    /// gone on since.
    static func isPrefix(_ existing: URL, of carried: URL) -> Bool {
        let size = fileSize(existing)
        guard size <= fileSize(carried), let mine = try? FileHandle(forReadingFrom: existing),
              let theirs = try? FileHandle(forReadingFrom: carried) else { return false }
        defer {
            try? mine.close()
            try? theirs.close()
        }
        var left = size
        while left > 0 {
            guard let a = try? mine.read(upToCount: min(left, 1 << 20)), let b = try? theirs.read(upToCount: a.count),
                  !a.isEmpty, a == b else { return false }
            left -= a.count
        }
        return true
    }

    /// `parts` under `root` with every link followed as the system would,
    /// as parts under `root`: nil when it leads outside `root` (through an
    /// absolute link or `..` above it) or through too many links.
    static func resolved(_ parts: [String], under root: String, hops: inout Int) -> [String]? {
        var at: [String] = []
        for part in parts {
            switch part {
            case "", ".": continue
            case "..":
                guard !at.isEmpty else { return nil }
                at.removeLast()
            default:
                let path = ([root] + at + [part]).joined(separator: "/")
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                    at.append(part)
                    continue
                }
                hops += 1
                guard hops <= 40, !target.hasPrefix("/"),
                      let followed = resolved(at + target.split(separator: "/").map(String.init), under: root, hops: &hops) else { return nil }
                at = followed
            }
        }
        return at
    }
}
