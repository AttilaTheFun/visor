import AgentProtocol
import Foundation

/// One line of Claude Code's `--output-format stream-json`, read as what it
/// means for the conversation: its session, its rows, its tools, the end of
/// a turn. A line it doesn't know means nothing.
public enum ClaudeLine: Sendable, Equatable {
    /// The session began (or resumed): its id and model.
    case started(sessionID: String, model: String)
    /// Words the agent wrote: a row, by the message's id and the block's
    /// place in it.
    case text(id: String, text: String)
    /// The agent thought (its words are its own, not shown).
    case thinking
    /// A tool call began.
    case toolStarted(id: String, name: String, label: String)
    /// A tool call's result came back.
    case toolFinished(id: String)
    /// The turn ended: whether in error, and why.
    case turnEnded(error: String?)

    /// What `line` means, in order; none for a line that isn't JSON or isn't known.
    public static func read(_ line: String) -> [ClaudeLine] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else { return [] }
            return [.started(sessionID: session, model: object["model"] as? String ?? "")]
        case "assistant":
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
            let messageID = message["id"] as? String ?? UUID().uuidString
            return content.enumerated().compactMap { index, block in
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                    return .text(id: "\(messageID)-\(index)", text: text)
                case "thinking":
                    return .thinking
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    return .toolStarted(id: block["id"] as? String ?? "\(messageID)-\(index)", name: name,
                                        label: label(name, block["input"] as? [String: Any] ?? [:]))
                default:
                    return nil
                }
            }
        case "user":
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id)
            }
        case "result":
            let failed = object["is_error"] as? Bool ?? false
            return [.turnEnded(error: failed ? (object["result"] as? String ?? object["subtype"] as? String ?? "failed") : nil)]
        default:
            return []
        }
    }

    /// A tool call in a few words: its name, and its command, file or
    /// pattern when it has one.
    static func label(_ name: String, _ input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "url", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                let short = value.count > 80 ? String(value.prefix(80)) + "…" : value
                return "\(name): \(short)"
            }
        }
        return name
    }

    /// A user's turn, as `--input-format stream-json` takes it: one line.
    public static func userTurn(_ text: String) -> String {
        let turn: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        let data = (try? JSONSerialization.data(withJSONObject: turn)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
