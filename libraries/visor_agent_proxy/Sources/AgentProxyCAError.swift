/// What agent-proxy's authority refuses (MultiPass's RunnerCAError).
public enum AgentProxyCAError: Error, Equatable {
    /// A leaf for a host it doesn't open.
    case notGitHub(String)
}
