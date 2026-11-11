/// How an agent ended.
package struct AgentExit: Sendable {
    package let status: Int32
    /// Ended by a signal rather than by exiting.
    package let signaled: Bool
}
