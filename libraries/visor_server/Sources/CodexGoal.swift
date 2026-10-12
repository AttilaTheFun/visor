/// A Codex thread's goal, as its app-server tells it: what Codex works
/// toward until it is met, and where that stands.
struct CodexGoal: Sendable, Equatable {
    var objective: String
    /// active, paused, blocked, usageLimited, budgetLimited or complete.
    var status: String
    var tokensUsed: Int
    var timeUsedSeconds: Int

    init(objective: String, status: String, tokensUsed: Int = 0, timeUsedSeconds: Int = 0) {
        self.objective = objective
        self.status = status
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
    }

    /// A goal as the app-server's JSON has it.
    init?(_ json: Any?) {
        guard let object = json as? [String: Any], let objective = object["objective"] as? String else { return nil }
        self.init(objective: objective, status: object["status"] as? String ?? "active",
                  tokensUsed: object["tokensUsed"] as? Int ?? 0, timeUsedSeconds: object["timeUsedSeconds"] as? Int ?? 0)
    }

    var met: Bool { status == "complete" }

    /// Where it stands, in words.
    var summary: String {
        let state = switch status {
        case "active": "being worked on"
        case "paused": "paused (/goal resume)"
        case "blocked": "stalled (/goal resume)"
        case "usageLimited": "stopped at the usage limits (/goal resume)"
        case "budgetLimited": "stopped at its token budget"
        case "complete": "achieved"
        default: status
        }
        let minutes = timeUsedSeconds / 60
        let spent = timeUsedSeconds > 0 ? ", \(minutes > 0 ? "\(minutes) min" : "\(timeUsedSeconds) s") so far" : ""
        return "Goal: \(objective) — \(state)\(spent)."
    }
}
