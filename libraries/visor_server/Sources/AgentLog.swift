// Every agent's own log, read the one way: Claude Code's session JSONL,
// Codex's rollout JSONL, and the openrouter CLI's message JSONL are each
// read into lines of the shape Claude's parser gives — a node with the line
// it follows, and what it says — so one indexer, one cache and one
// assembler make every agent's transcript. The log is the transcript: what
// the user sent is no row until the agent's log has it.

import ClaudeTranscript
import Foundation
import VisorProtocol

/// Reads a log's whole lines into lines of Claude's shape. Stateful: a log
/// that is a plain list links each line to the one before, across reads.
protocol AgentLogParser: AnyObject, Sendable {
    func lines(in data: Data) -> [ClaudeLine]
    /// The last line already read (from the cache), when reading resumes
    /// part-way through the log.
    func resume(after key: String?)
}

/// Claude Code's own session file: already a tree of lines.
final class ClaudeLogParser: AgentLogParser, @unchecked Sendable {
    func lines(in data: Data) -> [ClaudeLine] { ClaudeTranscriptParser.lines(in: data) }
    func resume(after key: String?) {}
}

/// A log that is a list: each line follows the one before it. The
/// assistant's items between two other kinds of line are one message.
class LinearLogParser: @unchecked Sendable {
    private var last: String?
    private var run: String?
    private var counter = 0

    func resume(after key: String?) { last = key }

    /// A line with this key (or a made-up one), following the last.
    func line(key: String?, type: String, record: (String) -> ClaudeRecord.Kind?, timestamp: String?) -> ClaudeLine {
        counter += 1
        let key = key ?? "line-\(counter)-\(UUID().uuidString.prefix(6))"
        let kind = record(key)
        // The user speaking, or a tool answering, ends the assistant's run.
        switch kind {
        case .user?, .toolResult?: run = nil
        default: break
        }
        let line = ClaudeLine(uuid: key, parentUuid: last, type: type,
                              record: kind.map { ClaudeRecord(uuid: key, kind: $0, timestamp: timestamp) })
        last = key
        return line
    }

    /// The message an assistant item belongs to: the run it continues, or
    /// one it starts under its own key.
    func message(_ key: String) -> String {
        if let run { return run }
        run = key
        return key
    }

    static func objects(in data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }
}

/// Codex's rollout: `response_item`s are the conversation — the user's and
/// the assistant's messages, tool calls and their outputs; everything else
/// (events, context, token counts) is bookkeeping, kept as nodes only.
final class CodexRolloutParser: LinearLogParser, AgentLogParser, @unchecked Sendable {
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

/// The openrouter CLI's log: a line per message of the conversation, in
/// the chat API's shape (user, assistant with tool calls, tool).
final class OpenRouterLogParser: LinearLogParser, AgentLogParser, @unchecked Sendable {
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

/// Where each agent keeps a session's log, and how to read it.
enum AgentLog {
    static func locate(agent: AgentKind, id: String, cwd: String) -> (url: URL, parser: AgentLogParser)? {
        switch agent {
        case .claude:
            return ClaudeSessionFiles.locate(sessionID: id, cwd: cwd).map { ($0, ClaudeLogParser()) }
        case .codex:
            return SessionCatalog.codexRollout(id: id).map { ($0, CodexRolloutParser()) }
        case .openrouter:
            let url = SessionCatalog.openrouterRoot.appendingPathComponent("sessions/\(id).jsonl")
            return FileManager.default.fileExists(atPath: url.path) ? (url, OpenRouterLogParser()) : nil
        }
    }
}
