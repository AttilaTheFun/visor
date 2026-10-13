/// A session offered for moving to another server, as the server it is on
/// describes it (`POST /api/migration/offer`): the session, the agent's own
/// files that hold its conversation, and the projects it works in. The
/// client shows it to the server it is moving to, which answers with what
/// it will do (MigrationPlan), and carries the files across.
public struct MigrationOffer: Codable, Equatable, Sendable {
    /// Names the offer on the server it came from, for reading its files.
    public var token: String
    /// The computer the session is on, by name.
    public var from: String
    public var session: SessionInfo
    /// The agent's own id for the conversation, which the new session
    /// resumes.
    public var resumeID: String
    /// The home folder there: a path under it lands under the home folder
    /// where the session goes.
    public var home: String
    public var files: [MigrationFile]
    /// The session's own folder's first, then the others it works in, most
    /// mentioned first.
    public var projects: [MigrationProject]

    public init(token: String, from: String, session: SessionInfo, resumeID: String, home: String, files: [MigrationFile],
                projects: [MigrationProject]) {
        self.token = token
        self.from = from
        self.session = session
        self.resumeID = resumeID
        self.home = home
        self.files = files
        self.projects = projects
    }

    /// The bytes the conversation's files come to.
    public var size: Int { files.reduce(0) { $0 + $1.size } }
}
