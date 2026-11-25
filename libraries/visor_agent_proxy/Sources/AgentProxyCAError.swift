/// What agent-proxy's authority refuses (MultiPass's RunnerCAError).
public enum AgentProxyCAError: Error, Equatable {
    /// A leaf for a host it doesn't open.
    case notGitHub(String)
    /// A leaf for a host another authority's scope (Anthropic's) doesn't
    /// cover.
    case notItsHost(String)
}
