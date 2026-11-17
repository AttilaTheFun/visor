/// A git repository a session works in, as the server it is on sees it,
/// for moving the session to a runner (VisorServer+Driven), which clones
/// it there. (A move to another server carries no projects.)
public struct MigrationProject: Codable, Equatable, Sendable {
    public var path: String
    /// Where it can be cloned from, its branch and commit, and whether it
    /// holds anything the remote does not (changes, files git does not
    /// ignore, commits not pushed).
    public var remote: String?
    public var branch: String?
    public var commit: String?
    public var unshared: Bool

    public init(path: String, remote: String? = nil, branch: String? = nil, commit: String? = nil, unshared: Bool = false) {
        self.path = path
        self.remote = remote
        self.branch = branch
        self.commit = commit
        self.unshared = unshared
    }

    public var isRepository: Bool { commit != nil }
}
