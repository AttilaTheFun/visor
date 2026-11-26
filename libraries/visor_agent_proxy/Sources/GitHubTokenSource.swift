/// Where the interceptor gets its token (MultiPass's, moved): asked for a
/// caller's request to a repository, kept a while, and forgotten when GitHub
/// turns it down. Visor's is the GitHub App's installation tokens where its
/// key and id are kept (GitHubAppTokens), else the auth token Settings ›
/// Agent Proxy keeps (ConfiguredGitHubToken), one for all
/// (PreferredGitHubToken); a test's is fixed.
protocol GitHubTokenSource: Sendable {
    func token(session: String, repository: String) async throws -> String
    func forget(session: String, repository: String) async
    /// The git identity the container's agents commit as: the GitHub App's
    /// bot, where the source is the App's (PreferredGitHubToken); nil for
    /// any other.
    func identity() async -> GitHubAppIdentity?
}

extension GitHubTokenSource {
    /// An auth token, or a test's fixed one, is no one's: no identity.
    func identity() async -> GitHubAppIdentity? { nil }
}

/// What a source throws when it has no token to give: none is configured.
/// Not a token GitHub turned down, nor one that couldn't be made: then
/// nothing goes on. With none configured, a read of an allowed repository
/// goes on anonymously, as one outside them does (Logan, 9 Nov 2026: public
/// reads need no token); anything else is refused with the error's words.
protocol NoGitHubToken: Error {}
