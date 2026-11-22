// Where a session's turn stands, one state at a time: the person's message
// on its way, the agent thinking, the agent writing its reply, the agent
// waiting on something, or nothing at all. Ephemeral, like the turn's
// status lines: never the record, and never kept across a restart. The
// reply's words are not part of it: they come with its row, when the row
// syncs (docs/protocol.md, The turn's state).

/// One session's turn, as its server sees it now.
public struct TurnState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The person's message is on its way to the agent, which hasn't
        /// begun its turn yet.
        case sending
        /// The model is thinking, or hasn't said anything yet.
        case thinking
        /// The model is writing its reply: words are coming.
        case responding
        /// The agent waits on something (`waits`): a tool call, a
        /// subagent, an approval, a sign-in, or work it left running in
        /// the background when its turn ended.
        case waiting
        /// Nothing is going on.
        case idle
    }

    public var phase: Phase
    /// For `waiting`: what it waits on, in the order the agent began them.
    /// Empty otherwise.
    public var waits: [TurnWait]

    public init(_ phase: Phase, waits: [TurnWait] = []) {
        self.phase = phase
        self.waits = phase == .waiting ? waits : []
    }

    public static let idle = TurnState(.idle)
    public var isIdle: Bool { phase == .idle }
}
