/// Sessions backed up to a folder on a server's computer (`/api/backups`):
/// what a move to another server would carry of each — the agent's own
/// files for its conversation and the session as it was, never its
/// projects — kept there to be restored from. One half of a move each way (MigrationOffer), with a
/// folder in the middle, for an update that might lose sessions.
public struct SessionBackup: Codable, Equatable, Sendable {
    /// The folder, on the server's computer.
    public var path: String
    /// When it was made, in seconds since 1970.
    public var created: Double
    /// The computer it was made on, by name.
    public var from: String
    public var sessions: [SessionBackupItem]
    /// The bytes it holds.
    public var size: Int
    /// Whether it was imported from a session archive (`POST /api/import`)
    /// rather than backed up here: restoring its session is refused while
    /// that session is on the computer.
    public var imported: Bool

    public init(path: String, created: Double, from: String, sessions: [SessionBackupItem], size: Int, imported: Bool = false) {
        self.path = path
        self.created = created
        self.from = from
        self.sessions = sessions
        self.size = size
        self.imported = imported
    }
}
