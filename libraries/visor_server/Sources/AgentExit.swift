/// How an agent ended.
struct AgentExit: Sendable {
    let status: Int32
    /// Ended by a signal rather than by exiting.
    let signaled: Bool
}
