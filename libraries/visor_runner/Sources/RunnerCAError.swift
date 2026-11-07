/// What the CA refuses.
public enum RunnerCAError: Error, Equatable {
    /// A leaf for a host the proxy doesn't open.
    case notGitHub(String)
}
