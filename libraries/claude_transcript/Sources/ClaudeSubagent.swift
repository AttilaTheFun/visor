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
            return ClaudeSubagent(id: id, toolUseID: object["toolUseId"] as? String,
                                  description: object["description"] as? String ?? "",
                                  type: object["agentType"] as? String ?? "",
                                  finished: object["finished"] as? Bool ?? false,
                                  transcript: folder.appendingPathComponent("agent-\(id).jsonl"))
        }
    }
}
