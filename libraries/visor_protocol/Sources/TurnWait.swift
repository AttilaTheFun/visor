/// One thing a waiting turn waits on (`TurnState.waits`).
public struct TurnWait: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A tool call waiting for the person's Allow or Deny.
        case approval
        /// The agent's questions, waiting for the person's answers.
        case question
        /// Claude's sign-in (`/login`), waiting for its code.
        case signIn
        /// A tool call running, until its result comes.
        case tool
        /// A subagent the agent sent off (the Agent or Task tool), or one
        /// it left running in the background.
        case subagent
        /// Work the agent left running in the background when its turn
        /// ended: a command run in the background, a monitor.
        case background
    }

    public var kind: Kind
    /// The tool call's, the approval's or the background task's id.
    public var id: String
    /// What it is, in a line: a tool call's name and the gist of its input
    /// ("Bash: bazel test //tests:linux"), a subagent's description, an
    /// approval's summary, a background task's description.
    public var label: String
    /// What sort of work a tool call or a background task is (a shell, a
    /// monitor, a subagent, another tool), for its symbol; nil for an
    /// approval, a question or a sign-in.
    public var work: StatusItem.Kind?

    public init(kind: Kind, id: String, label: String, work: StatusItem.Kind? = nil) {
        self.kind = kind; self.id = id; self.label = label; self.work = work
    }
}
