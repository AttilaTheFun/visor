/// A question about a session's conversation that does not go into it
/// (`/btw`): the agent answers from what it knows, using no tools, even
/// while it works. A session keeps its side questions, in the order
/// asked, until the person ends them.
public struct SideQuestion: Codable, Hashable, Sendable, Identifiable {
    /// The client's id for it.
    public var id: String
    public var question: String
    /// Nil while the agent thinks it over.
    public var answer: String?
    /// Why there is no answer, when there will be none.
    public var failure: String?
    /// When it was asked: seconds since 1970.
    public var asked: Double

    public init(id: String, question: String, answer: String? = nil, failure: String? = nil, asked: Double) {
        self.id = id
        self.question = question
        self.answer = answer
        self.failure = failure
        self.asked = asked
    }

    /// Answered, or never to be.
    public var settled: Bool { answer != nil || failure != nil }
}
