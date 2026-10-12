/// What the server a session moves to will do (`POST /api/migration/plan`):
/// where the session runs there, and for each project whether it is there
/// already, is cloned, copied, or only made.
public struct MigrationPlan: Codable, Equatable, Sendable {
    /// Names the move there, for the files written to it and its end.
    public var id: String
    public var cwd: String
    /// Whether the agent's tool is installed there.
    public var agentInstalled: Bool
    public var steps: [MigrationStep]

    public init(id: String, cwd: String, agentInstalled: Bool, steps: [MigrationStep]) {
        self.id = id
        self.cwd = cwd
        self.agentInstalled = agentInstalled
        self.steps = steps
    }
}
