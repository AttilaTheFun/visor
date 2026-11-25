// Which GitHub credential the gate attaches, decided at each request from
// the secrets as kept now: the GitHub App's installation tokens
// (GitHubAppTokens) when its key and its id are both set; otherwise
// Settings' auth token (ConfiguredGitHubToken), as before the App came back;
// otherwise none, and what needs a token is refused. An App whose key or id
// is missing isn't the App: its other secrets alone change nothing.

import Foundation

/// The App's tokens, else Settings' auth token.
struct PreferredGitHubToken: GitHubTokenSource {
    let app: GitHubAppTokens
    /// The App's secrets as kept now: nil unless its key and id are both set.
    let appSecrets: @Sendable () -> GitHubAppSecrets?
    let configured: ConfiguredGitHubToken

    func token(session: String, repository: String) async throws -> String {
        if let secrets = appSecrets() { return try await app.token(secrets) }
        return try await configured.token(session: session, repository: repository)
    }

    func forget(session: String, repository: String) async {
        await app.forget()
        await configured.forget(session: session, repository: repository)
    }
}
