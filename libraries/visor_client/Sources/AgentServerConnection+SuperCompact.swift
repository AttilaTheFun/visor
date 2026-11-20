// Super Compact from a session's menu (SuperCompact; docs/super-compact.md).

extension AgentServerConnection {
    /// Whether this computer's server condenses a session's conversation
    /// into HANDOFF.md and carries the session on from it.
    public var superCompacts: Bool { server.superCompacts }
}
