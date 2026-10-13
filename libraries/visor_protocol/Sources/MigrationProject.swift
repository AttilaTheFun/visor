/// A folder a moving session works in, as it is where the session is.
public struct MigrationProject: Codable, Equatable, Sendable {
    public var path: String
    /// For a git repository: where it can be cloned from, its branch and
    /// commit, and whether it holds anything the remote does not (changes,
    /// files git does not ignore, commits not pushed).
    public var remote: String?
    public var branch: String?
    public var commit: String?
    public var unshared: Bool
    /// What a copy would carry, in bytes: what git does not ignore, and
    /// its history.
    public var size: Int
    /// How often the conversation names it.
    public var mentions: Int

    public init(path: String, remote: String? = nil, branch: String? = nil, commit: String? = nil, unshared: Bool = false,
                size: Int = 0, mentions: Int = 0) {
        self.path = path
        self.remote = remote
        self.branch = branch
        self.commit = commit
        self.unshared = unshared
        self.size = size
        self.mentions = mentions
    }

    public var isRepository: Bool { commit != nil }
}
