// The agents' own session stores, for resuming a conversation that began
// elsewhere: Claude Code keeps one JSONL per session under
// ~/.claude/projects/<cwd with / and . as ->/, Codex one rollout JSONL per
// session under ~/.codex/sessions/<y>/<m>/<d>/. Both are read for the first
// user prompt (the title) and the time. The openrouter CLI keeps one JSON
// per session under ~/.openrouter/sessions/ (OPENROUTER_HOME moves it).

import ClaudeTranscript
import Foundation
import VisorProtocol

enum SessionCatalog {
    /// The newest sessions of `agent` started in `cwd` (or anywhere when empty).
    static func resumable(agent: AgentKind, cwd: String) -> [ResumableSession] {
        let wanted = cwd.isEmpty ? nil : (cwd as NSString).expandingTildeInPath
        switch agent {
        case .claude: return claude(cwd: wanted)
        case .codex: return codex(cwd: wanted)
        case .openrouter: return openrouter(cwd: wanted)
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude's directory per project: the path with every "/", "." and
    /// "_" turned into "-" (universal_ui → universal-ui). Miss the
    /// underscore and the folder is simply not found.
    static func projectDirectory(for cwd: String) -> String {
        var name = (cwd as NSString).expandingTildeInPath
        for character in ["/", ".", "_"] { name = name.replacingOccurrences(of: character, with: "-") }
        return name
    }

    /// Puts a session's history where its folder looks for it.
    ///
    /// Claude fixes a session's project directory when the session starts
    /// and keeps writing there for good, so renaming the folder leaves the
    /// conversation behind under the old name: `claude --resume` run in
    /// the new folder cannot see it, and neither can we. Here we find the
    /// history by its id, wherever it is, and give it a second name in the
    /// directory the folder uses now.
    ///
    /// A hard link rather than a copy: one file under two names, so it
    /// does not matter which side writes next and a large transcript is
    /// not duplicated. Returns whether anything was adopted.
    @discardableResult
    static func adoptHistory(agent: AgentKind, id: String, cwd: String) -> Bool {
        // Codex keeps its rollouts in one date tree and resumes by id
        // alone, so a rename never hides them from `codex resume`.
        guard agent != .codex, !id.isEmpty, !cwd.isEmpty else { return false }
        let files = FileManager.default
        let root = home.appendingPathComponent(".claude/projects")
        let target = root.appendingPathComponent(projectDirectory(for: cwd))
        let wanted = target.appendingPathComponent(id + ".jsonl")
        guard !files.fileExists(atPath: wanted.path) else { return false }
        let elsewhere = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .map { $0.appendingPathComponent(id + ".jsonl") }
            .first { files.fileExists(atPath: $0.path) }
        guard let elsewhere else { return false }
        try? files.createDirectory(at: target, withIntermediateDirectories: true)
        do { try files.linkItem(at: elsewhere, to: wanted) } catch {
            guard (try? files.copyItem(at: elsewhere, to: wanted)) != nil else { return false }
        }
        return true
    }

    private static func claude(cwd: String?) -> [ResumableSession] {
        let root = home.appendingPathComponent(".claude/projects")
        var directories: [URL] = []
        // Looking in one folder's own directory is itself the filter: what
        // is in there belongs to it. Comparing the `cwd` recorded inside as
        // well hides a session whose folder was renamed after it started —
        // Claude keeps writing to the directory it opened with.
        let byDirectory = cwd != nil
        if let cwd {
            directories = [root.appendingPathComponent(projectDirectory(for: cwd))]
        } else {
            directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }
        var files: [(URL, Date)] = []
        for directory in directories {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((file, date))
            }
        }
        files.sort { $0.1 > $1.1 }
        var result: [ResumableSession] = []
        for (file, date) in files.prefix(200) {
            guard result.count < 40, let head = head(of: file) else { continue }
            // The name the session goes by, best first: the one its owner
            // gave it, the one Claude wrote for it, then its opening words.
            var named: String?
            var written: String?
            var spoken: String?
            var sessionCWD: String?
            for line in head.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if sessionCWD == nil, let c = object["cwd"] as? String { sessionCWD = c }
                if named == nil, let t = object["customTitle"] as? String, !t.isEmpty { named = t }
                if written == nil, let t = object["aiTitle"] as? String, !t.isEmpty { written = t.replacingOccurrences(of: "-", with: " ") }
                guard spoken == nil, object["type"] as? String == "user", object["isSidechain"] as? Bool != true,
                      let message = object["message"] as? [String: Any] else { continue }
                let text: String
                if let s = message["content"] as? String { text = s }
                else if let parts = message["content"] as? [[String: Any]] { text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ") }
                else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("<") { continue }
                spoken = trimmed
            }
            let id = file.deletingPathExtension().lastPathComponent
            if !byDirectory, let cwd, let sessionCWD, sessionCWD != cwd { continue }
            // A long conversation's first records can be one enormous line
            // that the head cuts in half, leaving nothing to read: name it
            // by its id rather than dropping it from the list.
            let title = named ?? written ?? spoken ?? "Session \(id.prefix(8))"
            result.append(ResumableSession(id: id, agent: .claude,
                                           cwd: sessionCWD ?? cwd ?? "", title: String(title.prefix(80)),
                                           timestamp: date.timeIntervalSince1970))
        }
        return result
    }

    /// ~/.openrouter, or OPENROUTER_HOME — the CLI's own rule.
    static var openrouterRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["OPENROUTER_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".openrouter", isDirectory: true)
    }

    /// The default model the CLI is configured with, if any.
    static func openrouterDefaultModel() -> String? {
        guard let data = try? Data(contentsOf: openrouterRoot.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    private static func openrouterSession(id: String) -> [String: Any]? {
        let file = openrouterRoot.appendingPathComponent("sessions").appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func openrouter(cwd: String?) -> [ResumableSession] {
        let directory = openrouterRoot.appendingPathComponent("sessions")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
        var result: [ResumableSession] = []
        for name in names {
            let id = String(name.dropLast(5))
            guard let object = openrouterSession(id: id), let sessionCWD = object["cwd"] as? String else { continue }
            if let cwd, (sessionCWD as NSString).expandingTildeInPath != cwd { continue }
            let messages = (object["messages"] as? [[String: Any]]) ?? []
            let spoken = messages.first { $0["role"] as? String == "user" }?["content"] as? String
            let line = spoken?.split(separator: "\n").first.map(String.init) ?? ""
            let title = line.isEmpty ? "Session \(id.prefix(8))" : String(line.prefix(80))
            result.append(ResumableSession(id: id, agent: .openrouter, cwd: sessionCWD, title: title,
                                           timestamp: (object["updated"] as? Double) ?? 0))
        }
        return Array(result.sorted { $0.timestamp > $1.timestamp }.prefix(40))
    }

    /// The CLI's messages as rows: the user's words, the assistant's with
    /// its tool calls as activities, and the tool results (hidden rows).
    private static func openrouterTranscript(id: String) -> [TranscriptEntry] {
        guard let object = openrouterSession(id: id), let messages = object["messages"] as? [[String: Any]] else { return [] }
        var rows: [TranscriptEntry] = []
        for (index, message) in messages.enumerated() {
            let text = message["content"] as? String ?? ""
            switch message["role"] as? String {
            case "user":
                rows.append(TranscriptEntry(id: "or-user-\(index)", role: .user, text: text))
            case "assistant":
                let calls = (message["tool_calls"] as? [[String: Any]]) ?? []
                let activities = calls.compactMap { call -> String? in
                    guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
                    let arguments = (function["arguments"] as? String).flatMap { JSON.object($0) }
                    return "\(name): \(JSON.summary(arguments))"
                }
                if text.isEmpty && activities.isEmpty { continue }
                rows.append(TranscriptEntry(id: "or-assistant-\(index)", role: .assistant, text: text, activities: activities))
            case "tool":
                rows.append(TranscriptEntry(id: "or-tool-\(index)", role: .tool, text: String(text.prefix(400)), toolName: "tool_result"))
            default:
                continue
            }
        }
        return rows
    }

    private static func codex(cwd: String?) -> [ResumableSession] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [(URL, Date)] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((file, date))
        }
        files.sort { $0.1 > $1.1 }
        var result: [ResumableSession] = []
        for (file, date) in files.prefix(300) {
            guard result.count < 40, let head = head(of: file) else { continue }
            var id: String?
            var sessionCWD: String?
            var title: String?
            for line in head.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any] else { continue }
                if object["type"] as? String == "session_meta" {
                    id = payload["id"] as? String ?? payload["session_id"] as? String
                    sessionCWD = payload["cwd"] as? String
                    if let cwd, sessionCWD != cwd { break }
                }
                if object["type"] as? String == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "user",
                   let parts = payload["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty || text.hasPrefix("<") { continue }
                    title = text
                    break
                }
            }
            // Codex keeps its rollouts in a date tree, so the recorded cwd
            // is the only thing that says which folder a thread belongs to
            // — a folder renamed mid-thread does hide it here, and there is
            // no directory to fall back on. A thread with nothing readable
            // to call it is still listed, by its id.
            guard let id, let sessionCWD, cwd == nil || sessionCWD == cwd else { continue }
            let name = title ?? "Session \(id.prefix(8))"
            result.append(ResumableSession(id: id, agent: .codex, cwd: sessionCWD, title: String(name.prefix(80)),
                                           timestamp: date.timeIntervalSince1970))
        }
        return result
    }

    /// The conversation so far, from the agent's own store, as transcript
    /// entries (the last `limit` of them): what a resumed session shows
    /// before its first new turn.
    static func transcript(agent: AgentKind, id: String, cwd: String, limit: Int = 300) -> [TranscriptEntry] {
        let entries: [TranscriptEntry]
        switch agent {
        case .claude: entries = claudeTranscript(id: id, cwd: cwd)
        case .codex: entries = codexTranscript(id: id)
        case .openrouter: entries = openrouterTranscript(id: id)
        }
        return Array(entries.suffix(limit))
    }

    private static func claudeTranscript(id: String, cwd: String) -> [TranscriptEntry] {
        guard let file = ClaudeSessionFiles.locate(sessionID: id, cwd: cwd) else { return [] }
        return TranscriptAssembler.rows(in: ClaudeBranch.current(of: ClaudeTranscriptParser.lines(contentsOf: file)).records)
    }

    /// How full a Codex thread's context is: the tokens its last request
    /// carried and the model's window, from the `token_count` the rollout
    /// records after every turn.
    static func codexContext(id: String) -> (used: Int, limit: Int?)? {
        guard let file = codexRollout(id: id),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The tail is enough: the last record is the most recent turn's.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var found: (Int, Int?)?
        for line in text.split(separator: "\n") {
            guard line.contains("token_count"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = (object["payload"] as? [String: Any]) ?? (object["info"] as? [String: Any]),
                  let info = (payload["info"] as? [String: Any]) ?? payload["last_token_usage"].map({ _ in payload }),
                  let last = info["last_token_usage"] as? [String: Any] else { continue }
            let used = (last["total_tokens"] as? Int)
                ?? ((last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0))
            found = (used, info["model_context_window"] as? Int)
        }
        return found
    }

    /// The rollout file of a Codex thread.
    private static func codexRollout(id: String) -> URL? {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let candidate as URL in enumerator where candidate.pathExtension == "jsonl" && candidate.lastPathComponent.contains(id) {
            return candidate
        }
        return nil
    }

    private static func codexTranscript(id: String) -> [TranscriptEntry] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var file: URL?
        for case let candidate as URL in enumerator where candidate.pathExtension == "jsonl" && candidate.lastPathComponent.contains(id) {
            file = candidate
            break
        }
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var entries: [TranscriptEntry] = []
        var index = 0
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any] else { continue }
            index += 1
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                let parts = payload["content"] as? [[String: Any]] ?? []
                let text = parts.compactMap { part -> String? in
                    let kind = part["type"] as? String
                    return kind == "input_text" || kind == "output_text" ? part["text"] as? String : nil
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text.hasPrefix("<") { continue }
                // Each message is its own entry: text and tool calls keep their order.
                if role == "user" { entries.append(TranscriptEntry(id: "past-\(index)", role: .user, text: text)) }
                else if role == "assistant" { entries.append(TranscriptEntry(id: "past-\(index)", role: .assistant, text: text)) }
            case "function_call", "local_shell_call", "custom_tool_call":
                let label = codexCallLabel(payload)
                // A call after words opens its own entry, so the order of
                // what was said and what ran survives.
                if let last = entries.indices.last, entries[last].role == .assistant, entries[last].text.isEmpty {
                    entries[last].activities.append(label)
                } else {
                    entries.append(TranscriptEntry(id: "past-\(index)", role: .assistant, text: "", activities: [label]))
                }
            default:
                continue
            }
        }
        return entries
    }

    /// A rollout tool call as the live adapter would label it: web searches
    /// by their first query, shell commands by their first line.
    private static func codexCallLabel(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        let input = (payload["arguments"] as? String ?? payload["input"] as? String ?? "")
        if input.contains("web__run") {
            func value(after keys: [String]) -> String? {
                for key in keys {
                    if let range = input.range(of: key) {
                        let value = input[range.upperBound...].prefix { $0 != "\"" }
                        if !value.isEmpty { return String(value.prefix(80)) }
                    }
                }
                return nil
            }
            if let query = value(after: ["q:\"", "\"q\":\""]) { return "Search: " + query }
            if let page = value(after: ["ref_id:\"http", "\"ref_id\":\"http"]) { return "Open: http" + page }
            return "Browse"
        }
        let first = input.split(separator: "\n").first.map(String.init) ?? ""
        let shown = first.count > 80 ? String(first.prefix(80)) + "…" : first
        return (name == "exec" || name == "shell" ? "Shell" : name) + (shown.isEmpty ? "" : ": " + shown)
    }

    /// The first 256 KB of a session file as text: enough for the first prompt.
    private static func head(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 262_144)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The host's folders, for the client's picker.
enum HostFolders {
    static func resolve(_ path: String) -> String {
        let expanded = (path.isEmpty ? "~" : path) as NSString
        return expanded.expandingTildeInPath
    }

    /// The subfolders of `path` (hidden ones skipped), sorted.
    static func list(_ path: String) -> [String] {
        let resolved = resolve(path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? []
        return entries.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (resolved as NSString).appendingPathComponent(name), isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Whether the path is still a folder here. A project the user moved or
    /// renamed answers false, which is what the client shows an error for.
    static func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: resolve(path), isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    static func make(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: resolve(path), withIntermediateDirectories: true)) != nil
    }
}
