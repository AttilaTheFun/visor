// The repositories a session works in, as the server it is on sees them,
// for moving it to a runner (VisorServer+Driven), which clones each there:
// its own folder's, and those under the home folder its conversation
// worked in — each with what git says of it (where it can be cloned from,
// and whether it holds anything that remote does not). A move to another
// server carries none: its agent clones what it needs.

import Foundation
import VisorProtocol
import VisorSystem

enum ProjectSurvey {
    /// The session's folder (its repository, when it is in one) first,
    /// then the repositories the conversation worked in (`workedIn`), most
    /// worked in first.
    @concurrent
    static func projects(cwd: String, conversation: URL?, home: String, limit: Int = 12) async -> [MigrationProject] {
        let folder = HostFolders.resolve(cwd)
        let own = await repository(at: folder) ?? MigrationProject(path: folder)
        var found = [own]
        guard let conversation else { return found }
        var counts: [String: Int] = [:]
        var tops: [String: String?] = [:]
        for (named, count) in workedIn(conversation, under: home).sorted(by: { $0.value > $1.value }).prefix(300) {
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
        for (path, _) in counts.sorted(by: { $0.value > $1.value }).prefix(limit) {
            guard let project = await repository(at: path) else { continue }
            found.append(project)
        }
        return found
    }

    // MARK: Where the conversation worked

    /// The places under `home` the conversation worked in, by their first
    /// three parts, with how often: files its agent edited or wrote, and
    /// where it ran git or gh (a Bash command's paths) — not every place it
    /// merely named. Read a line at a time.
    static func workedIn(_ file: URL, under home: String) -> [String: Int] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let needle = Data("\"tool_use\"".utf8)
        var counts: [String: Int] = [:]
        var pending = Data()
        func take(_ line: Data) {
            guard line.range(of: needle) != nil, let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = row["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            for item in content where item["type"] as? String == "tool_use" {
                let input = item["input"] as? [String: Any] ?? [:]
                switch item["name"] as? String {
                case "Edit", "Write", "MultiEdit", "NotebookEdit":
                    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
                    if path.hasPrefix(home + "/"), let place = place(in: Data(path.utf8), after: home.utf8.count + 1, home: home) {
                        counts[place, default: 0] += 1
                    }
                case "Bash":
                    let command = input["command"] as? String ?? ""
                    guard command.range(of: #"(^|[\s;&|(])(git|gh)\s"#, options: .regularExpression) != nil else { continue }
                    let text = Data(command.utf8)
                    let mark = Data((home + "/").utf8)
                    var from = text.startIndex
                    while let found = text.range(of: mark, in: from..<text.endIndex) {
                        if let place = place(in: text, after: found.upperBound, home: home) { counts[place, default: 0] += 1 }
                        from = found.upperBound
                    }
                default:
                    continue
                }
            }
        }
        while true {
            let piece = (try? handle.read(upToCount: 8 << 20)) ?? Data()
            if piece.isEmpty {
                if !pending.isEmpty { take(pending) }
                break
            }
            pending.append(piece)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                take(Data(pending[start..<newline]))
                start = newline + 1
            }
            // What is left of a line, whole with the next piece.
            pending = Data(pending[start...])
        }
        return counts
    }

    /// The home folder's own folders never surveyed: the Library, and those
    /// a Mac guards behind a permission (Downloads, Documents, Desktop…).
    /// Not where a session's repositories are; and a `git` asked there
    /// waits on a dialog no one answers (a move to a runner hung on two, in
    /// Downloads).
    static let kept: Set<String> = ["Library", "Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music", "Public"]

    /// The place named at `start` (just past "<home>/"), by its first three
    /// parts; nil for a hidden folder or one of `kept`.
    private static func place(in text: Data, after start: Data.Index, home: String) -> String? {
        let stops: Set<UInt8> = Set("\"' \n\t\\`()[]{}<>|:;,*?".utf8)
        var stop = start
        while stop < text.endIndex, stop - start < 300, !stops.contains(text[stop]) { stop += 1 }
        let parts = String(decoding: text[start..<stop], as: UTF8.self).split(separator: "/").prefix(3).map(String.init)
        guard let first = parts.first, !first.hasPrefix("."), !kept.contains(first) else { return nil }
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
        return MigrationProject(path: top, remote: remote, branch: branch, commit: commit, unshared: remote == nil || changes || unpushed)
    }
}
