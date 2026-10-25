/// What a machine a session leases from oss is using (a VM, a simulator,
/// an emulator), as oss says; nothing where its oss does not say.
public struct LeaseUsage: Codable, Hashable, Sendable {
    /// oss's id for the lease, its platform and configuration.
    public var id: String
    public var platform: String
    public var config: String?
    /// The session that leases it.
    public var session: String?
    /// The cores it was given (none for a simulator, which is given none),
    /// and how many it is using: 100 is one core's worth.
    public var cpus: Int?
    public var cpuPercent: Double?
    /// The memory it was given, and how much it holds.
    public var memoryLimitBytes: Int64?
    public var memoryBytes: Int64?

    public init(id: String, platform: String, config: String? = nil, session: String? = nil, cpus: Int? = nil,
                cpuPercent: Double? = nil, memoryLimitBytes: Int64? = nil, memoryBytes: Int64? = nil) {
        self.id = id
        self.platform = platform
        self.config = config
        self.session = session
        self.cpus = cpus
        self.cpuPercent = cpuPercent
        self.memoryLimitBytes = memoryLimitBytes
        self.memoryBytes = memoryBytes
    }
}
