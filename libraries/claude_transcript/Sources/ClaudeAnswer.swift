/// One of the user's answers to a question the agent asked (Claude Code's
/// AskUserQuestion, Codex's request_user_input): what it asked, and what
/// the user chose or wrote.
public struct ClaudeAnswer: Sendable, Equatable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}
