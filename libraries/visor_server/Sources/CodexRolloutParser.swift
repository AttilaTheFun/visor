import ClaudeTranscript
import Foundation
import VisorProtocol

/// Codex's rollout: `response_item`s are the conversation — the user's and
/// the assistant's messages, tool calls and their outputs; everything else
/// (events, context, token counts) is bookkeeping, kept as nodes only.
final class CodexRolloutParser: LinearLogParser, AgentLogParser {
    func lines(in data: Data) -> [ClaudeLine] {
        Self.objects(in: data).map { object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            let timestamp = object["timestamp"] as? String
            let key = payload["id"] as? String ?? (object["ordinal"] as? Int).map { "codex-\($0)" }
            guard object["type"] as? String == "response_item" else {
                return line(key: key, type: object["type"] as? String ?? "event", record: { _ in nil }, timestamp: timestamp)
            }
            let kind = payload["type"] as? String ?? ""
            return line(key: key, type: kind, record: { key in
                switch kind {
                case "message":
                    let text = Self.text(payload["content"])
                    switch payload["role"] as? String {
                    case "user":
                        // Codex's own context (instructions, environment)
                        // comes as user messages in angle brackets.
                        if text.isEmpty || text.hasPrefix("<") { return nil }
                        return .user(text: text, images: [])
                    case "assistant":
                        guard !text.isEmpty else { return nil }
                        return .assistant(messageID: message(key), blocks: [.text(text)], stopReason: nil, model: nil, usage: nil)
                    default:
                        return nil
                    }
                case "function_call", "local_shell_call", "custom_tool_call":
                    let label = SessionCatalog.codexCallLabel(payload)
                    let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let input = parts.count > 1 ? ["description": parts[1]] : [String: String]()
                    let json = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return .assistant(messageID: message(key), blocks: [.toolUse(id: payload["call_id"] as? String ?? key, name: parts[0], inputJSON: json)],
                                      stopReason: nil, model: nil, usage: nil)
                case "function_call_output", "local_shell_call_output", "custom_tool_call_output":
                    let output = payload["output"]
                    let text = (output as? String) ?? Self.text(output)
                    return .toolResult(toolUseID: payload["call_id"] as? String, text: text, images: [], isError: false)
                default:
                    return nil
                }
            }, timestamp: timestamp)
        }
    }

    /// The words of a content array (input_text / output_text parts).
    static func text(_ content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            let kind = part["type"] as? String
            return kind == "input_text" || kind == "output_text" || kind == "text" ? part["text"] as? String : nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
