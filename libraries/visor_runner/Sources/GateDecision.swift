/// What GitHubGate makes of a request.
public enum GateDecision: Equatable, Sendable {
    /// It goes on to GitHub as it is, with the session's token, for this
    /// repository (nil: a read the token's own scope bounds).
    case allow(repository: String?)
    /// It goes on only once the proxy has read what this says, with the same
    /// token (docs/github-proxy.md, "Checks that read before they write").
    case check(GateCheck)
    /// It doesn't go on: the reason, in gh_mcp's words.
    case refuse(String)
}
