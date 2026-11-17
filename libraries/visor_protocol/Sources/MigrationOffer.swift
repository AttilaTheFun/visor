/// A session offered for moving to another server, as the server it is on
/// describes it (`POST /api/migration/offer`): the session, and the agent's
/// own files that hold its conversation (its transcript, its folder beside
/// it, Claude's memory). Never its projects: a session moved works in a new,
/// empty folder, and its agent clones what it needs there. The client shows
/// it to the server it is moving to, which answers with where the session
/// will run (MigrationPlan), and carries the files across.
public struct MigrationOffer: Codable, Equatable, Sendable {
    /// Names the offer on the server it came from, for reading its files.
    public var token: String
    /// The computer the session is on, by name.
    public var from: String
    public var session: SessionInfo
    /// The agent's own id for the conversation, which the new session
    /// resumes.
    public var resumeID: String
    /// The home folder there: a backup restored on another computer puts
    /// the session's folder under that one's home folder.
    public var home: String
    public var files: [MigrationFile]

    public init(token: String, from: String, session: SessionInfo, resumeID: String, home: String, files: [MigrationFile]) {
        self.token = token
        self.from = from
        self.session = session
        self.resumeID = resumeID
        self.home = home
        self.files = files
    }

    /// The bytes the conversation's files come to.
    public var size: Int { files.reduce(0) { $0 + $1.size } }
}
