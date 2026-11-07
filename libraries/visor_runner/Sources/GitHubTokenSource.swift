/// Where the GitHub proxy gets its token (docs/github-proxy.md): asked for a
/// session's request to a repository, kept a while, and forgotten when GitHub
/// turns it down. The Runner's is the agents' App's, one for all
/// (GitHubAppTokens); a test's is fixed.
protocol GitHubTokenSource: Sendable {
    func token(session: String, repository: String) async throws -> String
    func forget(session: String, repository: String) async
}
