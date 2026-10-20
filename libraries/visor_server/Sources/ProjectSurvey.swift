// The projects a session works in, as the server it is on sees them, for
// moving it to another computer: its own folder, and the git repositories
// under the home folder its conversation names most — each with what git
// says of it (where it can be cloned from, and whether it holds anything
// that remote does not), and packed for copying when it cannot be cloned.

import Foundation
import VisorProtocol

enum ProjectSurvey {
    /// The session's folder (its repository, when it is in one) first,
    /// then the repositories the conversation names, most named first.
    @concurrent
    static func projects(cwd: String, conversation: URL?, home: String, limit: Int = 12) async -> [MigrationProject] {
        let folder = HostFolders.resolve(cwd)
        let own = await repository(at: folder) ?? MigrationProject(path: folder)
        var found = [own]
        guard let conversation else { return found }
        var counts: [String: Int] = [:]
        var tops: [String: String?] = [:]
        for (named, count) in mentions(in: conversation, under: home).sorted(by: { $0.value > $1.value }).prefix(300) {
            guard let directory = existingFolder(named, under: home) else { continue }
            let top: String?
            if let known = tops[directory] {
                top = known
            } else {
                top = await toplevel(of: directory)
                tops[directory] = top
            }
            guard let top, top != home, top != own.path, top.hasPrefix(home + "/") else { continue }
            counts[top, default: 0] += count
        }
        for (path, count) in counts.sorted(by: { $0.value > $1.value }).prefix(limit) {
            guard var project = await repository(at: path) else { continue }
            project.mentions = count
            found.append(project)
        }
        return found
    }

    // MARK: What the conversation names

    /// How often the file names each place under `home`, by the place's
    /// first three parts ("/Users/x/Developer/visor/Sources"), skipping the
    /// home folder's hidden folders and its Library. Read a piece at a
    /// time: a conversation runs to hundreds of megabytes.
    static func mentions(in file: URL, under home: String) -> [String: Int] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let needle = Data((home + "/").utf8)
        let reach = 400
        var counts: [String: Int] = [:]
        var carried = Data()
        while true {
            let piece = (try? handle.read(upToCount: 8 << 20)) ?? Data()
            let last = piece.isEmpty
            let text = carried + piece
            // A name that starts too near the end waits for the next piece,
            // where it is whole.
            let end = last ? text.endIndex : max(text.startIndex, text.endIndex - reach)
            var from = text.startIndex
            while let found = text.range(of: needle, in: from..<text.endIndex), found.lowerBound < end {
                if let place = place(in: text, after: found.upperBound, home: home) { counts[place, default: 0] += 1 }
                from = found.upperBound
            }
            if last { break }
            carried = Data(text[end...])
        }
        return counts
    }

    /// The place named at `start` (just past "<home>/"), by its first three
    /// parts; nil for a hidden folder or the Library.
    private static func place(in text: Data, after start: Data.Index, home: String) -> String? {
        let stops: Set<UInt8> = Set("\"' \n\t\\`()[]{}<>|:;,*?".utf8)
        var stop = start
        while stop < text.endIndex, stop - start < 300, !stops.contains(text[stop]) { stop += 1 }
        let parts = String(decoding: text[start..<stop], as: UTF8.self).split(separator: "/").prefix(3).map(String.init)
        guard let first = parts.first, !first.hasPrefix("."), first != "Library" else { return nil }
        return home + "/" + parts.joined(separator: "/")
    }

    /// The deepest folder there is among the place and its parents, below
    /// the home folder.
    private static func existingFolder(_ place: String, under home: String) -> String? {
        var path = place
        while path.count > home.count + 1 {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { return path }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: What git says

    private static var git: String { ToolPath.resolve("git") ?? "/usr/bin/git" }

    /// What git prints in `folder`, trimmed; nil when it fails.
    static func git(_ arguments: [String], in folder: String) async -> String? {
        guard let result = await Command.output(git, ["-C", folder] + arguments, environment: ToolPath.environment()),
              result.status == 0 else { return nil }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func toplevel(of folder: String) async -> String? {
        await git(["rev-parse", "--show-toplevel"], in: folder).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The repository `path` is in, as git describes it; nil when it is in
    /// none.
    static func repository(at path: String) async -> MigrationProject? {
        guard let top = await toplevel(of: path) else { return nil }
        let commit = await git(["rev-parse", "HEAD"], in: top)
        var remote = await git(["config", "--get", "remote.origin.url"], in: top)
        if remote?.isEmpty != false, let first = await git(["remote"], in: top)?.split(separator: "\n").first {
            remote = await git(["remote", "get-url", String(first)], in: top)
        }
        if remote?.isEmpty == true { remote = nil }
        let branch = await git(["symbolic-ref", "--short", "-q", "HEAD"], in: top).flatMap { $0.isEmpty ? nil : $0 }
        let changes = await git(["status", "--porcelain"], in: top).map { !$0.isEmpty } ?? true
        let unpushed = await git(["rev-list", "-n", "1", "HEAD", "--not", "--remotes"], in: top).map { !$0.isEmpty } ?? true
        var size = folderSize(top + "/.git")
        for file in await carried(in: top) { size += Self.size(of: top + "/" + file) }
        return MigrationProject(path: top, remote: remote, branch: branch, commit: commit, unshared: remote == nil || changes || unpushed,
                                size: size)
    }

    /// The files a copy of the repository carries, relative to it: what git
    /// tracks and what it does not ignore, that is there.
    static func carried(in top: String) async -> [String] {
        guard let listed = await Command.output(git, ["-C", top, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                                environment: ToolPath.environment()), listed.status == 0 else { return [] }
        let names = Set(listed.text.split(separator: "\0").map(String.init))
        return names.sorted().filter { FileManager.default.fileExists(atPath: top + "/" + $0) }
    }

    /// A copy of the repository packed as one file (a gzipped tar of what
    /// `carried` names and its .git), at `archive`.
    static func pack(_ top: String, into archive: URL) async -> String? {
        let list = archive.deletingPathExtension().appendingPathExtension("list")
        let names = await carried(in: top) + [".git"]
        do { try Data(names.joined(separator: "\0").utf8).write(to: list) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: list) }
        guard let result = await Command.output(ToolPath.resolve("tar") ?? "/usr/bin/tar", ["-czf", archive.path, "-C", top, "--null", "-T", list.path], errors: true)
        else { return "tar could not be started" }
        return result.status == 0 ? nil : result.text
    }

    private static func size(of path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func folderSize(_ path: String) -> Int {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walk { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
