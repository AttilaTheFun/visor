/// Where the interceptor gets its token (MultiPass's, moved): asked for a
/// caller's request to a repository, kept a while, and forgotten when GitHub
/// turns it down. Visor's is the auth token Settings › Agent Proxy keeps,
/// one for all (ConfiguredGitHubToken); a test's is fixed.
protocol GitHubTokenSource: Sendable {
    func token(session: String, repository: String) async throws -> String
    func forget(session: String, repository: String) async
}

/// What a source throws when it has no token to give: none is configured.
/// Not a token GitHub turned down, nor one that couldn't be made: then
/// nothing goes on. With none configured, a read of an allowed repository
/// goes on anonymously, as one outside them does (Logan, 9 Nov 2026: public
/// reads need no token); anything else is refused with the error's words.
protocol NoGitHubToken: Error {}
