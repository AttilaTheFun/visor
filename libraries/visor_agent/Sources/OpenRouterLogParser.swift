import ClaudeTranscript
import Foundation
import VisorProtocol

/// The openrouter CLI's log: a line per message of the conversation, in
/// the chat API's shape (user, assistant with tool calls, tool).
final class OpenRouterLogParser: LinearLogParser, AgentLogParser {
    func lines(in data: Data) -> [ClaudeLine] {
        Self.objects(in: data).map { object in
            let message = object["message"] as? [String: Any] ?? [:]
            let role = message["role"] as? String ?? ""
            let content = message["content"] as? String ?? ""
            return line(key: object["id"] as? String, type: role, record: { key in
                switch role {
                case "user":
                    return content.isEmpty ? nil : .user(text: content, images: [])
                case "assistant":
                    var blocks: [ClaudeBlock] = content.isEmpty ? [] : [.text(content)]
                    for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                        let function = call["function"] as? [String: Any] ?? [:]
                        blocks.append(.toolUse(id: call["id"] as? String ?? key, name: function["name"] as? String ?? "tool",
                                               inputJSON: function["arguments"] as? String ?? "{}"))
                    }
                    return blocks.isEmpty ? nil : .assistant(messageID: key, blocks: blocks, stopReason: nil, model: nil, usage: nil)
                case "tool":
                    return .toolResult(toolUseID: message["tool_call_id"] as? String, text: content, images: [], isError: false)
                default:
                    return nil
                }
            }, timestamp: object["timestamp"] as? String)
        }
    }
}
