import Foundation
import VisorProtocol

/// What a line from the app server says, as far as the server cares: read
/// off the main actor.
enum CodexOutput: Sendable {
    /// The answer to a request of ours: the thread or turn it names, or
    /// what went wrong.
    case reply(id: Int, thread: String?, turn: String?, error: String?, goal: CodexGoal??)
    /// The app server asking us something (an approval).
    case asked(id: Int, method: String)
    /// Codex asking the user (request_user_input): each question with the
    /// id the answer goes back under.
    case questions(id: Int, [(id: String, question: AgentQuestion)])
    case text(item: String, String)
    case toolStarted(id: String, name: String, label: String)
    case reasoningStarted
    /// A turn began: one asked for, or one Codex started itself (working
    /// toward its goal, a review).
    case turnStarted(id: String)
    /// The thread's goal as it is now; nil once it is cleared.
    case goal(CodexGoal?)
    case itemCompleted(id: String, reasoning: Bool)
    /// The turn ended; with what went wrong, unless it was interrupted.
    case turnCompleted(failure: String?)
    case tokens(used: Int, limit: Int?)
    /// The thread's running total of tokens.
    case spent(SessionUsage)
    /// How the account is paid for (an answer to `account/read`).
    case plan(String, subscription: Bool)
    /// The account's windows and credits, whole or in part.
    case rateLimits(RateLimits)
    case failure(String)

    /// One of request_user_input's questions, as the user is shown it.
    /// Codex takes words of the user's own where `isOther` (the sheet
    /// always offers them).
    static func question(_ item: [String: Any]) -> (id: String, question: AgentQuestion)? {
        guard let id = item["id"] as? String, let text = item["question"] as? String else { return nil }
        let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
            guard let label = option["label"] as? String else { return nil }
            return AgentQuestion.Option(label: label, description: option["description"] as? String ?? "")
        }
        return (id, AgentQuestion(question: text, header: item["header"] as? String ?? "", options: options))
    }

    static func parse(_ line: String) -> [CodexOutput] {
        guard let object = JSON.object(line) else { return [] }
        if let id = object["id"] as? Int, object["method"] == nil {
            let result = object["result"] as? [String: Any]
            // A goal's answers carry the goal (null when there is none).
            let goal: CodexGoal?? = result?.keys.contains("goal") == true ? .some(CodexGoal(result?["goal"])) : .none
            var outputs: [CodexOutput] = [.reply(id: id, thread: (result?["thread"] as? [String: Any])?["id"] as? String,
                                                  turn: (result?["turn"] as? [String: Any])?["id"] as? String,
                                                  error: object["error"].map(describe), goal: goal)]
            if case .some(let now) = goal { outputs.append(.goal(now)) }
            // The account's reads, told by what they hold.
            if let account = result?["account"] as? [String: Any], let type = account["type"] as? String {
                switch type {
                case "chatgpt": outputs.append(.plan(planName(account["planType"] as? String ?? "plan"), subscription: true))
                case "apiKey": outputs.append(.plan("API key", subscription: false))
                default: outputs.append(.plan(type, subscription: false))
                }
            }
            if let snapshot = result?["rateLimits"] as? [String: Any] { outputs.append(.rateLimits(RateLimits(snapshot))) }
            return outputs
        }
        guard let method = object["method"] as? String else { return [] }
        if let id = object["id"] as? Int, method == "item/tool/requestUserInput" {
            let asked = (object["params"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []
            return [.questions(id: id, asked.compactMap(question))]
        }
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
        case "turn/started":
            guard let id = (params["turn"] as? [String: Any])?["id"] as? String else { return [] }
            return [.turnStarted(id: id)]
        case "thread/goal/updated":
            guard let goal = CodexGoal(params["goal"]) else { return [] }
            return [.goal(goal)]
        case "thread/goal/cleared":
            return [.goal(nil)]
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            var failure: String?
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty,
               (turn["status"] as? String) != "interrupted" {
                failure = message
            }
            return [.turnCompleted(failure: failure)]
        case "thread/tokenUsage/updated":
            // The last request's tokens are what the context holds; the
            // total is the thread's.
            guard let usage = params["tokenUsage"] as? [String: Any] ?? params["usage"] as? [String: Any] else { return [] }
            var outputs: [CodexOutput] = []
            let used = ((usage["last"] as? [String: Any])?["totalTokens"] as? Int) ?? (usage["totalTokens"] as? Int) ?? 0
            if used > 0 { outputs.append(.tokens(used: used, limit: usage["modelContextWindow"] as? Int ?? usage["contextWindow"] as? Int)) }
            if let total = usage["total"] as? [String: Any] {
                outputs.append(.spent(SessionUsage(input: Int64(total["inputTokens"] as? Int ?? 0),
                                                   cached: Int64(total["cachedInputTokens"] as? Int ?? 0),
                                                   output: Int64(total["outputTokens"] as? Int ?? 0))))
            }
            return outputs
        case "account/rateLimits/updated":
            guard let snapshot = params["rateLimits"] as? [String: Any] else { return [] }
            return [.rateLimits(RateLimits(snapshot))]
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
