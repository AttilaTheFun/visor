// What a move here takes from the server it comes from, held to where it
// belongs. The offer's ids, places, folders and archives are the other
// server's words, and a server compromised or wrong could name `..`, an
// absolute path, a `/` inside an id, or an archive whose entries lead out:
// a move takes ids only as plain names (SessionPathName: letters, digits,
// `-` and `_`), the conversation's id only as one an agent makes (a UUID),
// and full paths only with nothing to resolve (no `.`, `..` or empty
// part); writes nothing outside the move's own folder, the agent's place
// for that conversation, or the folder a project's step names; and unpacks
// an archive only into a folder of its own inside where it goes, every
// entry's name and every link it makes checked to stay there, before
// anything is moved into place. A clone is walked the same way before it
// is kept: a repository can check out links too.

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
    static func isPlainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        while parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        if parts == [""] { return true }
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Why the offer (a move's, or a backup's) can't come here as it is:
    /// nil when it can.
    static func unsafeOffer(_ offer: MigrationOffer) -> String? {
        guard SessionCatalog.isConversationID(offer.resumeID) else {
            return "its conversation's id, “\(offer.resumeID)”, is not one an agent makes"
        }
        guard isPlainPath(offer.session.cwd) else { return "the session's folder, \(offer.session.cwd), is not a full path" }
        var ids: Set<String> = []
        for file in offer.files {
            guard isCarriedName(file.id), ids.insert(file.id).inserted else { return "it names a file “\(file.id)”" }
            guard file.place.isEmpty || SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: offer.session.cwd,
                                                                    resume: offer.resumeID) != nil else {
                return "it would put a file at \(file.place), which is not where the agent keeps its conversation"
            }
        }
        for project in offer.projects where !isPlainPath(project.path) {
            return "a project of its, \(project.path), is not a full path"
        }
        return nil
    }

    /// Why `path`, a project's step's, is no place to clone or unpack a
    /// project into: nil when it is. A full path with nothing to resolve,
    /// never the root; where repositories are kept apart, inside them.
    func notAProjectPlace(_ path: String) -> String? {
        guard Self.isPlainPath(path), path.contains(where: { $0 != "/" }) else { return "\(path) is not a full path to put a project at." }
        if let sources = sessionFolders?.sources,
           !SessionPathName.isInside(URL(fileURLWithPath: path, isDirectory: true), URL(fileURLWithPath: sources, isDirectory: true)) {
            return "\(path) is not in \(sources), where repositories are kept here."
        }
        return nil
    }

    // MARK: Unpacking

    /// A gzipped tar unpacked into `folder` (made when missing): every
    /// entry's name checked first (never absolute, never through `..`;
    /// under `name` alone when one is given), then unpacked into a folder of
    /// its own inside `folder`, walked (unsafeTree), and only then moved
    /// into place: `name` where nothing is by that name but an empty folder
    /// (never over what is there), or everything into `folder`. What went
    /// wrong, if anything; the folder it was unpacked into goes either way.
    static func unpack(_ archive: URL, into folder: URL, only name: String? = nil) async -> String? {
        if let name, !isCarriedName(name) { return "\(name) is not a name to unpack as" }
        if let name, let there = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path) {
            let empty = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path))?.isEmpty == true
            guard there[.type] as? FileAttributeType == .typeDirectory, empty else { return "\(name) is in \(folder.path) already" }
        }
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        // Listed as written (`-P`: no leading `/` taken off), so the names
        // checked are the archive's own.
        guard let listed = await Command.output(tar, ["-t", "-P", "-z", "-f", archive.path]) else { return "tar could not be started" }
        guard listed.status == 0 else { return "it is not an archive tar can read" }
        for entry in listed.text.split(separator: "\n") where !entry.isEmpty {
            if let problem = unsafeEntry(String(entry), only: name) { return problem }
        }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".visor-unpacking-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard SessionPathName.isInside(staging, folder), (try? files.createDirectory(at: staging, withIntermediateDirectories: false)) != nil else {
            return "could not make a folder to unpack into in \(folder.path)"
        }
        defer { removeTree(staging) }
        guard let result = await Command.output(tar, ["--no-same-owner", "--no-same-permissions", "-xzf", archive.path, "-C", staging.path],
                                                errors: true) else { return "tar could not be started" }
        guard result.status == 0 else { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let problem = unsafeTree(staging) { return problem }
        let top = ((try? files.contentsOfDirectory(atPath: staging.path)) ?? []).sorted()
        if let name {
            guard top == [name] else { return "it holds \(top.joined(separator: ", ")), not \(name) alone" }
        }
        for item in top {
            let destination = folder.appendingPathComponent(item, isDirectory: false)
            guard SessionPathName.isInside(destination, folder) else { return "\(item) would lead out of \(folder.path)" }
            // The empty folder by that name, the one thing it may take the place of.
            if name != nil { try? files.removeItem(at: destination) }
            do { try files.moveItem(at: staging.appendingPathComponent(item, isDirectory: false), to: destination) } catch {
                return "could not put \(item) in \(folder.path): \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// Why an archive's entry (as `tar -t` lists it) can't be unpacked: an
    /// absolute name, one through `..`, or one not under `only`.
    static func unsafeEntry(_ entry: String, only name: String?) -> String? {
        guard !entry.hasPrefix("/") else { return "it holds an entry at an absolute path, \(entry)" }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.contains("..") else { return "it holds an entry that leads out, \(entry)" }
        if let name, let first = parts.first, first != name { return "it holds \(entry), not under \(name)" }
        return nil
    }

    /// Why what was unpacked or cloned at `root` can't be kept: a link
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
    static func openUp(_ path: String) {
        let files = FileManager.default
        guard let mode = (try? files.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber,
              mode.intValue & 0o700 != 0o700 else { return }
        try? files.setAttributes([.posixPermissions: NSNumber(value: mode.intValue | 0o700)], ofItemAtPath: path)
    }

    /// What is at `url` removed, every folder in it opened first (an
    /// archive's or a clone's folder of mode 0000 can't be emptied as it is).
    static func removeTree(_ url: URL) {
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
