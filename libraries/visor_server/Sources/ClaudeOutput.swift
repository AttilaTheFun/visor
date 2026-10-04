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
    /// The run began: its session id, the model it runs, and where its
    /// key came from ("none": a subscription's login).
    case began(session: String?, model: String?, keySource: String?)
    /// A new assistant message is starting to stream.
    case messageStarted(id: String?)
    case text(String)
    /// A block of the message began: thinking, or something else.
    case blockStarted(thinking: Bool)
    /// A whole assistant message: its model, the tokens its request
    /// carried, the tools it calls.
    case assistant(model: String?, tokens: Int, tools: [Tool])
    case toolResults([String])
    /// The turn ended; with what went wrong, if it failed, and the run's
    /// usage so far.
    case result(failure: String?, spent: SessionUsage?)
    /// The account's windows and budgets: a subscription's rate limits,
    /// or the openrouter CLI's key and credits.
    case limits([UsageLimit])

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
                outputs.append(.began(session: object["session_id"] as? String, model: object["model"] as? String,
                                      keySource: object["apiKeySource"] as? String))
            }
            if object["subtype"] as? String == "usage_limits" { outputs.append(.limits(Self.keyLimits(object))) }
            return outputs
        case "rate_limit_event":
            guard let info = object["rate_limit_info"] as? [String: Any] else { return [] }
            return [.limits(Self.windows(info))]
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
            return [.result(failure: failed ? (object["result"] as? String) ?? "The turn failed" : nil, spent: Self.spent(object))]
        default:
            return []
        }
    }
}

extension ClaudeOutput {
    /// The run's usage so far, from a result: every model's tokens (a
    /// subagent's too) and the cost Claude Code reckons. Its running total
    /// is the process's, and carries on across a resume only when Claude
    /// Code restores it.
    static func spent(_ result: [String: Any]) -> SessionUsage? {
        guard let models = result["modelUsage"] as? [String: [String: Any]], !models.isEmpty else { return nil }
        var usage = SessionUsage(cost: result["total_cost_usd"] as? Double)
        for model in models.values {
            let cached = model["cacheReadInputTokens"] as? Int ?? 0
            usage.input += (model["inputTokens"] as? Int ?? 0) + cached + (model["cacheCreationInputTokens"] as? Int ?? 0)
            usage.cached += cached
            usage.output += model["outputTokens"] as? Int ?? 0
        }
        return usage
    }

    /// A subscription's rolling windows, from a rate-limit event: each
    /// window's share used and when it resets — the five-hour and the
    /// weekly first, then any others (a model's own week).
    static func windows(_ info: [String: Any]) -> [UsageLimit] {
        var windows = info["unifiedWindows"] as? [String: [String: Any]] ?? [:]
        // An older event names only the window it is about.
        if windows.isEmpty, let type = info["rateLimitType"] as? String {
            windows[type] = ["utilization": info["utilization"] as Any, "resetsAt": info["resetsAt"] as Any]
        }
        let order = ["five_hour", "seven_day"]
        let keys = windows.keys.sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
        return keys.compactMap { key in
            guard let window = windows[key], let used = window["utilization"] as? Double else { return nil }
            return UsageLimit(name: windowName(key), used: used, resets: window["resetsAt"] as? Double)
        }
    }

    /// "five_hour" → "5-hour", "seven_day" → "Weekly", "seven_day_opus" →
    /// "Weekly (Opus)".
    static func windowName(_ key: String) -> String {
        for (prefix, name) in [("five_hour", "5-hour"), ("seven_day", "Weekly")] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count).split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return rest.isEmpty ? name : "\(name) (\(rest))"
        }
        let words = key.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The openrouter CLI's key and credits (its `usage_limits` line,
    /// OpenRouter's own figures, in dollars): the key's limit if it has
    /// one, and what is left of the credits bought.
    static func keyLimits(_ line: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        if let key = line["key"] as? [String: Any], let limit = key["limit"] as? Double, limit > 0 {
            let left = key["limit_remaining"] as? Double ?? max(0, limit - (key["usage"] as? Double ?? 0))
            limits.append(UsageLimit(name: "Key limit", used: min(1, max(0, (limit - left) / limit)),
                                     resets: (key["limit_reset"] as? String).flatMap { nextReset($0, after: Date()) },
                                     left: left, total: limit, unit: .dollars))
        }
        if let credits = line["credits"] as? [String: Any], let total = credits["total_credits"] as? Double, total > 0 {
            let spent = credits["total_usage"] as? Double ?? 0
            limits.append(UsageLimit(name: "Credits", used: min(1, max(0, spent / total)), left: max(0, total - spent), total: total, unit: .dollars))
        }
        return limits
    }

    /// When an OpenRouter key's limit next starts over: at midnight UTC,
    /// the week's on a Monday, the month's on the first.
    static func nextReset(_ period: String, after now: Date) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let next: Date?
        switch period {
        case "daily": next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        case "weekly": next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 2), matchingPolicy: .nextTime)
        case "monthly": next = calendar.nextDate(after: now, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        default: next = nil
        }
        return next?.timeIntervalSince1970
    }
}
