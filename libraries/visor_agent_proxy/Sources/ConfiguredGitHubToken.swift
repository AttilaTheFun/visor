// The token GitHub's requests go on with in Visor (Logan, 19 Nov 2026: no
// hard dependency on his GitHub Apps): the auth token Settings › Agent
// Proxy keeps, a GitHub credential of the owner's choosing (a fine-grained
// personal access token, a bot account's, an App's installation token kept
// fresh by something else), one for every agent, which none of them sees.
// It replaced Shireworks' GitHubAppTokens (logan-shire-agent's JWT and
// installation tokens), which are back in 0.71.1 as a choice that comes
// before it when the App's key and id are kept (GitHubAppTokens,
// PreferredGitHubToken). Read as it is kept now at each request (the host
// reads its secret at most once a minute), so a new one is taken without a
// restart. Without one, a request that needs a token is refused: container
// sessions have no GitHub through the proxy but what the gate lets through
// anonymously.

import Foundation

/// Settings' auth token, as it is now.
struct ConfiguredGitHubToken: GitHubTokenSource {
    /// Why there's no token to send.
    struct Missing: NoGitHubToken, CustomStringConvertible {
        var description: String {
            "agent-proxy has no auth token for GitHub (Settings › Agent Proxy, or `agent-proxy secret-set github-token`)"
        }
    }

    /// The token kept now; nil or empty for none.
    let current: @Sendable () -> String?

    func token(session: String, repository: String) async throws -> String {
        guard let token = current()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { throw Missing() }
        return token
    }

    /// Nothing held here to forget: the next request reads it again.
    func forget(session: String, repository: String) async {}
}
