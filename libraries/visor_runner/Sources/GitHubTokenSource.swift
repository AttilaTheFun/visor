/// Where the GitHub proxy gets a session's token (docs/github-proxy.md,
/// "Tokens from Keymaster"): one for a repository, asked for the session,
/// kept a while, and forgotten when GitHub turns it down.
protocol GitHubTokenSource: Sendable {
    func token(session: String, repository: String) async throws -> String
    func forget(session: String, repository: String) async
}
