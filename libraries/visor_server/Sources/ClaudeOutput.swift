import Foundation
import VisorProtocol

/// What a line of Claude Code's output says, as far as the server cares:
/// read off the main actor, so a long line (a tool's whole result) costs
/// it nothing.
enum ClaudeOutput: Sendable, Equatable {
    struct Tool: Sendable, Equatable {
        let id: String?
        let name: String
        let label: String
        let tasks: [TaskItem]?
    }

    case commands([SlashCommand])
    /// The run began: its session id and the model it runs.
    case began(session: String?, model: String?)
    /// A new assistant message is starting to stream.
    case messageStarted(id: String?)
    case text(String)
    /// A block of the message began: thinking, or something else.
    case blockStarted(thinking: Bool)
    /// A whole assistant message: its model, the tokens its request
    /// carried, the tools it calls.
    case assistant(model: String?, tokens: Int, tools: [Tool])
    case toolResults([String])
    /// The turn ended; with what went wrong, if it failed.
    case result(failure: String?)

    static func parse(_ line: String) -> [ClaudeOutput] {
        guard let object = JSON.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            var outputs: [ClaudeOutput] = []
            // The commands it takes, with what each does: at the start of
            // a run, and again whenever they change (a skill installed).
            if object["subtype"] as? String == "commands_changed", let list = object["commands"] as? [[String: Any]] {
                outputs.append(.commands(list.compactMap { item in
                    guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                    return SlashCommand(name: name, description: item["description"] as? String ?? "", argumentHint: item["argumentHint"] as? String ?? "")
                }))
            }
            if object["subtype"] as? String == "init" {
                outputs.append(.began(session: object["session_id"] as? String, model: object["model"] as? String))
            }
            return outputs
        case "stream_event":
            guard let event = object["event"] as? [String: Any], let kind = event["type"] as? String else { return [] }
            if kind == "message_start", let message = event["message"] as? [String: Any] {
                return [.messageStarted(id: message["id"] as? String)]
            } else if kind == "content_block_delta", let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                return [.text(text)]
            } else if kind == "content_block_start", let block = event["content_block"] as? [String: Any] {
                return [.blockStarted(thinking: block["type"] as? String == "thinking")]
            }
            return []
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            // The request's own tokens: what the context holds right now.
            let usage = message["usage"] as? [String: Any] ?? [:]
            let tokens = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
            let tools = content.filter { $0["type"] as? String == "tool_use" }.map { block in
                let name = block["name"] as? String ?? "tool"
                return Tool(id: block["id"] as? String, name: name, label: "\(name): \(JSON.summary(block["input"]))",
                            tasks: TurnStatus.tasks(named: name, input: block["input"] as? [String: Any]))
            }
            return [.assistant(model: message["model"] as? String, tokens: tokens, tools: tools)]
        case "user":
            // A tool result: the tool finished. (Its row comes from the log.)
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
            return [.toolResults(content.filter { $0["type"] as? String == "tool_result" }.compactMap { $0["tool_use_id"] as? String })]
        case "result":
            let failed = object["is_error"] as? Bool == true
            return [.result(failure: failed ? (object["result"] as? String) ?? "The turn failed" : nil)]
        default:
            return []
        }
    }
}
