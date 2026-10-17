/// A question the agent asks the user, and waits on (Claude Code's
/// AskUserQuestion): what it asks, a short label for it, the answers it
/// offers, and whether more than one may be chosen. The user may answer in
/// words of their own instead.
public struct AgentQuestion: Codable, Hashable, Sendable {
    /// One answer offered, and what choosing it means.
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        public var description: String

        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    /// A word or two for it ("Approach", "Library").
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String = "", options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}
