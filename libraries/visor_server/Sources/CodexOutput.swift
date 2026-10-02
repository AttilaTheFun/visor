import Foundation
import VisorProtocol

/// What a line from the app server says, as far as the server cares: read
/// off the main actor.
enum CodexOutput: Sendable {
    /// The answer to a request of ours: the thread or turn it names, or
    /// what went wrong.
    case reply(id: Int, thread: String?, turn: String?, error: String?)
    /// The app server asking us something (an approval).
    case asked(id: Int, method: String)
    case text(item: String, String)
    case toolStarted(id: String, name: String, label: String)
    case reasoningStarted
    case itemCompleted(id: String, reasoning: Bool)
    /// The turn ended; with what went wrong, unless it was interrupted.
    case turnCompleted(failure: String?)
    case tokens(used: Int, limit: Int?)
    case failure(String)

    static func parse(_ line: String) -> [CodexOutput] {
        guard let object = JSON.object(line) else { return [] }
        if let id = object["id"] as? Int, object["method"] == nil {
            let result = object["result"] as? [String: Any]
            return [.reply(id: id, thread: (result?["thread"] as? [String: Any])?["id"] as? String,
                           turn: (result?["turn"] as? [String: Any])?["id"] as? String,
                           error: object["error"].map(describe))]
        }
        guard let method = object["method"] as? String else { return [] }
        if let id = object["id"] as? Int { return [.asked(id: id, method: method)] }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"] as? String, let delta = params["delta"] as? String else { return [] }
            return [.text(item: item, delta)]
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return [] }
            let id = item["id"] as? String ?? UUID().uuidString
            switch item["type"] as? String {
            case "commandExecution":
                return [.toolStarted(id: id, name: "Bash", label: "Bash: \(short(item["command"] as? String ?? "command"))")]
            case "fileChange":
                return [.toolStarted(id: id, name: "Edit", label: "Edit: \(changeSummary(item))")]
            case "mcpToolCall":
                let name = item["tool"] as? String ?? "tool"
                return [.toolStarted(id: id, name: name, label: "\(name): \(short(JSON.summary(item["arguments"])))")]
            case "reasoning":
                return [.reasoningStarted]
            default:
                return []
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
            return [.itemCompleted(id: id, reasoning: item["type"] as? String == "reasoning")]
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            var failure: String?
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty,
               (turn["status"] as? String) != "interrupted" {
                failure = message
            }
            return [.turnCompleted(failure: failure)]
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any] ?? params["usage"] as? [String: Any] else { return [] }
            let used = (usage["total"] as? Int) ?? (usage["totalTokens"] as? Int) ?? (usage["inputTokens"] as? Int ?? 0)
            return used > 0 ? [.tokens(used: used, limit: usage["contextWindow"] as? Int ?? usage["modelContextWindow"] as? Int)] : []
        case "error":
            guard let message = (params["error"] as? [String: Any])?["message"] as? String ?? params["message"] as? String else { return [] }
            return [.failure(message)]
        default:
            return []
        }
    }

    private static func short(_ text: String, limit: Int = 80) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    private static func changeSummary(_ item: [String: Any]) -> String {
        let changes = item["changes"] as? [[String: Any]] ?? []
        let paths = changes.compactMap { $0["path"] as? String }
        return paths.isEmpty ? "files" : paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    private static func describe(_ error: Any) -> String {
        if let object = error as? [String: Any], let message = object["message"] as? String { return message }
        return "\(error)"
    }
}
