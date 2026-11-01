import Foundation

/// A subagent a Claude Code session sent off (its Agent tool), as Claude
/// Code keeps it beside the session's file: `<session>/subagents/agent-<id>
/// .meta.json`, with its conversation in `agent-<id>.jsonl` there.
public struct ClaudeSubagent: Sendable, Equatable {
    /// Claude Code's id for it, which its SendMessage takes.
    public let id: String
    /// The Agent call that sent it off.
    public let toolUseID: String?
    /// What it was sent to do, as the call described it.
    public let description: String
    /// Its kind ("Explore", "general-purpose", a custom agent's name).
    public let type: String
    /// Done with what it was sent to do: its meta file says so (which not
    /// every finished one's does), or its conversation's last word is an
    /// answer that ended its turn. One killed mid-work says neither.
    public let finished: Bool
    /// Its conversation's file.
    public let transcript: URL

    public init(id: String, toolUseID: String?, description: String, type: String, finished: Bool, transcript: URL) {
        self.id = id
        self.toolUseID = toolUseID
        self.description = description
        self.type = type
        self.finished = finished
        self.transcript = transcript
    }

    /// A session's subagents, oldest first, from the folder beside its file.
    public static func all(of sessionFile: URL) -> [ClaudeSubagent] {
        let folder = sessionFile.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let metas = files.filter { $0.lastPathComponent.hasPrefix("agent-") && $0.lastPathComponent.hasSuffix(".meta.json") }
        let made = { (url: URL) in (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return metas.sorted { made($0) < made($1) }.compactMap { meta in
            guard let data = try? Data(contentsOf: meta),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let id = String(meta.lastPathComponent.dropFirst("agent-".count).dropLast(".meta.json".count))
            let transcript = folder.appendingPathComponent("agent-\(id).jsonl")
            return ClaudeSubagent(id: id, toolUseID: object["toolUseId"] as? String,
                                  description: object["description"] as? String ?? "",
                                  type: object["agentType"] as? String ?? "",
                                  finished: object["finished"] as? Bool == true || endedItsTurn(transcript),
                                  transcript: transcript)
        }
    }

    /// Whether a subagent's conversation ends with its answer: the last of
    /// its messages is the assistant's, stopped at the end of its turn
    /// (not for a tool). Read from the file's end, all of it only when the
    /// last line is longer than the end read.
    static func endedItsTurn(_ transcript: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        for start in size > window ? [size - window, 0] : [0] {
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return false }
            // The first line of a window that starts mid-file is cut short.
            let lines = data.split(separator: 0x0A).dropFirst(start > 0 ? 1 : 0)
            for line in lines.reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                switch object["type"] as? String {
                case "assistant":
                    return (object["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
                case "user":
                    return false
                default:
                    continue
                }
            }
        }
        return false
    }
}
