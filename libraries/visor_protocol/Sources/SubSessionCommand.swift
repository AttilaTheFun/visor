/// Visor's own commands for a session's sub-sessions
/// (docs/sub-sessions.md), as typed: `/btw <question>`, `/fork [prompt]`
/// and `/branch [name]`. The agents have commands by these names too, for
/// their terminals; in Visor they are Visor's.
public enum SubSessionCommand: Equatable, Sendable {
    /// A side question; nil opens the session's side questions to ask one.
    case side(String?)
    /// A fork, started on the prompt when there is one.
    case fork(String?)
    /// A branch from the conversation's end, named when a name is given.
    case branch(String?)

    public init?(_ text: String) {
        // Trimmed by hand: the protocol builds where Foundation is not.
        let trimmed = text.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.prefix { !$0.isWhitespace }
        var rest = trimmed.dropFirst(word.count).drop(while: \.isWhitespace)
        while rest.last?.isWhitespace == true { rest = rest.dropLast() }
        let argument = rest.isEmpty ? nil : String(rest)
        switch word {
        case "/btw": self = .side(argument)
        case "/fork": self = .fork(argument)
        case "/branch": self = .branch(argument)
        default: return nil
        }
    }

    /// The menu's entries for them, in place of the agents' own.
    public static let offered = [
        SlashCommand(name: "btw", description: "Ask a side question about this conversation, without adding to it", argumentHint: "<question>"),
        SlashCommand(name: "fork", description: "Copy this conversation into a session of its own, and start it on a prompt", argumentHint: "[prompt]"),
        SlashCommand(name: "branch", description: "Copy this conversation into a session of its own, to go on from here", argumentHint: "[name]"),
    ]
}
