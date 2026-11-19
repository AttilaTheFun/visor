/// Where the interceptor gets its token (MultiPass's, moved): asked for a
/// caller's request to a repository, kept a while, and forgotten when GitHub
/// turns it down. Visor's is the auth token Settings › Agent Proxy keeps,
/// one for all (ConfiguredGitHubToken); a test's is fixed.
protocol GitHubTokenSource: Sendable {
    func token(session: String, repository: String) async throws -> String
    func forget(session: String, repository: String) async
}
