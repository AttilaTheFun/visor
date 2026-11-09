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
    /// It goes on to GitHub with no token at all: a read of a public
    /// repository outside the allowed ones, as anyone on the internet reads
    /// it (Logan, 9 Nov 2026: an agent's open-source dependencies). A private
    /// one stays out of reach: GitHub answers a read without a token with
    /// 404.
    case anonymous(repository: String)
}
