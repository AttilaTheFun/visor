import ClaudeTranscript
import Foundation
import VisorProtocol

/// Codex's rollout: `response_item`s are the conversation — the user's and
/// the assistant's messages, tool calls and their outputs; everything else
/// (events, context, token counts) is bookkeeping, kept as nodes only.
final class CodexRolloutParser: LinearLogParser, AgentLogParser {
    /// The goal as the log has said it so far: its objective (nil, none)
    /// and status. A goal event that says only this again is no command.
    private var goal: (objective: String?, status: String) = (nil, "active")
    /// The questions each request_user_input call asked, by its call id.
    private var questionsAsked: [String: [(id: String, question: String)]] = [:]

    func lines(in data: Data) -> [ClaudeLine] {
        Self.objects(in: data).map { object in
            let payload = object["payload"] as? [String: Any] ?? [:]
            let timestamp = object["timestamp"] as? String
            let key = payload["id"] as? String ?? (object["ordinal"] as? Int).map { "codex-\($0)" }
            guard object["type"] as? String == "response_item" else {
                // A goal the user changed, where the log says so only as an
                // event (codex 0.156 writes no "User set the goal" context):
                // the command as they typed it.
                if let command = goalCommand(event: payload) {
                    return line(key: "codex-goal-" + (timestamp ?? UUID().uuidString), type: "message",
                                record: { _ in .user(text: command, images: []) }, timestamp: timestamp)
                }
                return line(key: key, type: object["type"] as? String ?? "event", record: { _ in nil }, timestamp: timestamp)
            }
            let kind = payload["type"] as? String ?? ""
            // The questions Codex asked the user (request_user_input), by
            // the call they are answered under.
            if kind == "function_call", payload["name"] as? String == "request_user_input", let call = payload["call_id"] as? String {
                questionsAsked[call] = Self.questions(payload["arguments"])
            }
            let goalText = kind == "message" && payload["role"] as? String == "user" ? Self.goalCommand(Self.text(payload["content"])) : nil
            if let goalText { note(goalText) }
            return line(key: key, type: kind, record: { key in
                switch kind {
                case "message":
                    let text = Self.text(payload["content"])
                    switch payload["role"] as? String {
                    case "user":
                        // A goal the user set, paused, resumed or cleared:
                        // the command as they typed it.
                        if let goalText { return .user(text: goalText, images: []) }
                        if Self.isContext(text) { return nil }
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
                    // The user's answers to Codex's questions: theirs, by
                    // the questions' words.
                    if let call = payload["call_id"] as? String, let asked = self.questionsAsked[call], let answers = Self.answers(text, to: asked) {
                        return .answers(answers)
                    }
                    return .toolResult(toolUseID: payload["call_id"] as? String, text: text, images: [], isError: false)
                default:
                    return nil
                }
            }, timestamp: timestamp)
        }
    }

    /// request_user_input's questions (its arguments, as JSON): each id
    /// and the words asked, in order.
    static func questions(_ arguments: Any?) -> [(id: String, question: String)] {
        guard let text = arguments as? String, let object = JSON.object(text),
              let questions = object["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { question in
            guard let id = question["id"] as? String, let words = question["question"] as? String else { return nil }
            return (id, words)
        }
    }

    /// The answers in request_user_input's output
    /// (`{"answers": {<id>: {"answers": [...]}}}`), by the questions' words,
    /// in the order asked; nil for any other output (a turn stopped first).
    static func answers(_ output: String, to asked: [(id: String, question: String)]) -> [ClaudeAnswer]? {
        guard let object = JSON.object(output), let answers = object["answers"] as? [String: Any] else { return nil }
        let found = asked.compactMap { question -> ClaudeAnswer? in
            guard let given = (answers[question.id] as? [String: Any])?["answers"] as? [String], !given.isEmpty else { return nil }
            return ClaudeAnswer(question: question.question, answer: given.joined(separator: ", "))
        }
        return found.isEmpty ? nil : found
    }

    /// A goal command the log has written: the goal it leaves.
    private func note(_ command: String) {
        let words = command.dropFirst("/goal".count).trimmingCharacters(in: .whitespaces)
        switch words {
        case "clear": goal = (nil, "active")
        case "pause": goal.status = "paused"
        case "resume": goal.status = "active"
        default: goal = (words, "active")
        }
    }

    /// The command a goal event stands for, when it changes the goal the
    /// log has said: a new objective is `/goal …`, paused is `/goal pause`,
    /// active after paused `/goal resume`, cleared `/goal clear`. Where Codex also
    /// wrote the "User set the goal" context (0.162 does, just before), the
    /// event says nothing new. Codex's own changes — met, blocked, out of
    /// budget — are no command.
    func goalCommand(event payload: [String: Any]) -> String? {
        switch payload["type"] as? String {
        case "thread_goal_updated":
            guard let now = CodexGoal(payload["goal"]) else { return nil }
            let command: String?
            if goal.objective == nil || !CommandWords.same("/goal " + now.objective, "/goal " + (goal.objective ?? "")) {
                command = now.status == "active" || now.status == "paused" ? "/goal " + now.objective : nil
            } else if now.status == "paused", goal.status != "paused" {
                command = "/goal pause"
            } else if now.status == "active", goal.status == "paused" {
                command = "/goal resume"
            } else {
                command = nil
            }
            goal = (now.objective, now.status)
            return command
        case "thread_goal_cleared":
            defer { goal = (nil, "active") }
            return goal.objective == nil ? nil : "/goal clear"
        default:
            return nil
        }
    }

    /// What Codex writes when the user changes the goal, back as the
    /// command they typed: "User set the goal: \"…\"" is `/goal …`, a
    /// status alone is `/goal pause` or `/goal resume`, "User cleared the
    /// goal." is `/goal clear`. Nil for anything else.
    static func goalCommand(_ text: String) -> String? {
        guard text.hasPrefix("<codex_internal_context source=\"user_goal\">") else { return nil }
        if text.contains("User cleared the goal.") { return "/goal clear" }
        let set = "User set the goal: \""
        if let start = text.range(of: set) {
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\"\nUser set goal status:") ?? rest.range(of: "\"", options: .backwards)
            guard let end else { return nil }
            return "/goal " + rest[..<end.lowerBound]
        }
        if let status = text.range(of: "User set goal status: \"") {
            return text[status.upperBound...].hasPrefix("paused") ? "/goal pause" : "/goal resume"
        }
        return nil
    }

    /// Whether a user message in the rollout is Codex's own context, not
    /// the user's words: its instructions and environment, in angle
    /// brackets, or the AGENTS.md files it read ("# AGENTS.md instructions
    /// for <folder>").
    static func isContext(_ text: String) -> Bool {
        text.isEmpty || text.hasPrefix("<") || text.hasPrefix("# AGENTS.md instructions for ")
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
