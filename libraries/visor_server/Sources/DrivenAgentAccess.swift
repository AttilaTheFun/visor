// What a call made for a driven agent may do, as the one that holds the
// agent says from the token it shows (DrivenAgentDirectory): the
// dispatcher's JobQueue for a runner's agent, the container runner for one
// in the Sessions container.

/// What a call shown a bearer for an agent may do.
package enum DrivenAgentAccess: Equatable, Sendable {
    /// The agent's own token.
    case granted
    /// It holds no such agent (its job, or its place, is gone, or was never
    /// here).
    case unknown
    /// The agent's own token, but past its end.
    case expired
    /// A token missing, or not the agent's: why.
    case refused(String)
}
