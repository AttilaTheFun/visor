/// A subagent a session's agent sent off, as a client lists it: a row
/// above the session's composer and a capsule under its card, each opening
/// its conversation, until the person closes it.
public struct SubagentInfo: Codable, Hashable, Sendable, Identifiable {
    /// The agent's own id for it (what its SendMessage takes).
    public var id: String
    /// What it was sent to do.
    public var description: String
    /// Its kind ("Explore", "general-purpose", …).
    public var type: String
    /// Still working.
    public var running: Bool
    /// The agent's call that sent it off (Claude's Agent tool use).
    public var call: String?

    public init(id: String, description: String, type: String, running: Bool, call: String? = nil) {
        self.id = id
        self.description = description
        self.type = type
        self.running = running
        self.call = call
    }
}
