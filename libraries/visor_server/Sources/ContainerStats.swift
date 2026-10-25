/// One reading of a container's use: its processors' time so far and its
/// memory now.
public struct ContainerStats: Sendable, Equatable {
    /// The container's name.
    public var id: String
    /// Processor time it has used since it started, every core's together.
    public var cpuMicroseconds: UInt64
    /// The cores it may use.
    public var cpus: Int?
    public var memoryUsedBytes: UInt64?
    public var memoryLimitBytes: UInt64?

    public init(id: String, cpuMicroseconds: UInt64, cpus: Int? = nil, memoryUsedBytes: UInt64? = nil, memoryLimitBytes: UInt64? = nil) {
        self.id = id
        self.cpuMicroseconds = cpuMicroseconds
        self.cpus = cpus
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}
