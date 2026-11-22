import Foundation

/// What the tools reach the world through: GitHub, git, unzip, and where
/// they may write.
public struct Services: Sendable {
    public var transport: any GitHubTransport
    public var tokens: TokenCache
    public var git: Git
    public var unzip: String
    /// Where git_push and git_fetch reach a repository: GitHub over https
    /// (a test's: a local bare repository).
    public var remoteURL: @Sendable (RepoName) -> String
    /// Where gh_mcp makes its own scratch folders.
    public var scratch: String
    /// Folders artifact_download may write into besides checkouts.
    public var temporaryRoots: [String]

    public init(
        transport: any GitHubTransport, tokens: TokenCache, git: Git = Git(), unzip: String = "unzip",
        remoteURL: @escaping @Sendable (RepoName) -> String = { "https://github.com/\($0).git" },
        scratch: String = NSTemporaryDirectory(), temporaryRoots: [String] = ["/tmp", "/private/tmp"]
    ) {
        self.transport = transport
        self.tokens = tokens
        self.git = git
        self.unzip = unzip
        self.remoteURL = remoteURL
        self.scratch = scratch
        self.temporaryRoots = temporaryRoots
    }
}
