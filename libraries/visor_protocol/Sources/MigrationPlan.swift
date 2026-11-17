/// What the server a session moves to will do (`POST /api/migration/plan`):
/// where the session runs there — a new, empty folder of that server's
/// choosing — and whether its agent is installed.
public struct MigrationPlan: Codable, Equatable, Sendable {
    /// Names the move there, for the files written to it and its end.
    public var id: String
    public var cwd: String
    /// Whether the agent's tool is installed there.
    public var agentInstalled: Bool

    public init(id: String, cwd: String, agentInstalled: Bool) {
        self.id = id
        self.cwd = cwd
        self.agentInstalled = agentInstalled
    }
}
