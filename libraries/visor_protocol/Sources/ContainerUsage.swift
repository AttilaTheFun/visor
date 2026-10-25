/// What one of a computer's containers is using: a session's agent's
/// (`session`), or another the server does not know.
public struct ContainerUsage: Codable, Hashable, Sendable {
    /// The container's name.
    public var id: String
    /// The session whose agent runs in it.
    public var session: String?
    /// The processor cores it may use, and how many it is using: 100 is
    /// one core's worth.
    public var cpus: Int?
    public var cpuPercent: Double?
    /// The memory it may use, and how much it is using.
    public var memoryLimitBytes: Int64?
    public var memoryUsedBytes: Int64?

    public init(id: String, session: String? = nil, cpus: Int? = nil, cpuPercent: Double? = nil, memoryLimitBytes: Int64? = nil,
                memoryUsedBytes: Int64? = nil) {
        self.id = id
        self.session = session
        self.cpus = cpus
        self.cpuPercent = cpuPercent
        self.memoryLimitBytes = memoryLimitBytes
        self.memoryUsedBytes = memoryUsedBytes
    }
}
