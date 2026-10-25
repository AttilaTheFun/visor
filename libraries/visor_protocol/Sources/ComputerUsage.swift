/// A computer's processors and memory, as its server or its oss says
/// they are being used.
public struct ComputerUsage: Codable, Hashable, Sendable {
    /// The computer's name.
    public var name: String?
    /// Its processor cores.
    public var cpus: Int
    /// The processors at work: 100 is one core's worth, `cpus` × 100 all of
    /// them.
    public var cpuPercent: Double?
    /// Its memory, and how much of it is in use.
    public var memoryBytes: Int64
    public var memoryUsedBytes: Int64?

    public init(name: String? = nil, cpus: Int, cpuPercent: Double? = nil, memoryBytes: Int64, memoryUsedBytes: Int64? = nil) {
        self.name = name
        self.cpus = cpus
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryUsedBytes = memoryUsedBytes
    }
}
