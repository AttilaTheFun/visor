import AgentProtocol

/// What the wrapper says of its agent, as it happens: to its driver, and to
/// whoever watches it.
public enum WrapperOutput: Sendable, Equatable {
    /// A row, new or changed (the same id again replaces it).
    case entry(AgentProtocol_V1_TranscriptEntry)
    /// What it is doing now.
    case state(AgentProtocol_V1_EphemeralState)
    /// The harness's session id, once it has one, or when it changes.
    case sessionID(String)
    /// The agent ended: why.
    case ended(String)
}
