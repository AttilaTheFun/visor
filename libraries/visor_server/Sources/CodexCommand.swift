import VisorProtocol

/// A slash command typed to a Codex session, as Codex's own terminal
/// interface takes it: its app-server takes them as requests, not as
/// words of a turn, so they are made here. Anything else starting with a
/// slash goes to the agent as typed.
enum CodexCommand: Equatable {
    /// `/goal`: where the goal stands.
    case showGoal
    /// `/goal <objective>`: Codex works toward it, turn after turn, until
    /// it is met.
    case setGoal(String)
    case clearGoal
    case pauseGoal
    case resumeGoal
    /// `/compact`: the conversation summarized, to free the context.
    case compact
    /// `/review [instructions]`: a review of the uncommitted changes, or
    /// of what the instructions say.
    case review(String?)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        let rest = trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "goal":
            switch rest {
            case "": self = .showGoal
            case "clear": self = .clearGoal
            case "pause": self = .pauseGoal
            case "resume": self = .resumeGoal
            default: self = .setGoal(rest)
            }
        case "compact": self = .compact
        case "review": self = .review(rest.isEmpty ? nil : rest)
        default: return nil
        }
    }

    /// What the composer offers when "/" is typed in a Codex session.
    static let offered: [SlashCommand] = [
        SlashCommand(name: "goal", description: "Set a goal Codex works toward until it is met; alone, where it stands",
                     argumentHint: "[<objective>|pause|resume|clear]"),
        SlashCommand(name: "compact", description: "Summarize the conversation to free up context"),
        SlashCommand(name: "review", description: "Review the uncommitted changes, or what the instructions say", argumentHint: "[instructions]"),
    ]
}
