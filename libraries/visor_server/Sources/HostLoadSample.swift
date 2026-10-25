/// One reading of a computer's load: the processors' time so far (in the
/// system's ticks, every core's together), and its memory.
public struct HostLoadSample: Sendable, Equatable {
    /// Ticks spent working, and all ticks, since the computer started.
    public var busyTicks: UInt64
    public var totalTicks: UInt64
    public var cpus: Int
    public var memoryBytes: UInt64
    public var memoryUsedBytes: UInt64

    public init(busyTicks: UInt64, totalTicks: UInt64, cpus: Int, memoryBytes: UInt64, memoryUsedBytes: UInt64) {
        self.busyTicks = busyTicks
        self.totalTicks = totalTicks
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.memoryUsedBytes = memoryUsedBytes
    }

    /// The processors at work between `earlier` and this reading, 100 for
    /// each core's worth; nil when no time passed between them.
    public func cpuPercent(since earlier: HostLoadSample) -> Double? {
        guard totalTicks > earlier.totalTicks, busyTicks >= earlier.busyTicks else { return nil }
        let share = Double(busyTicks - earlier.busyTicks) / Double(totalTicks - earlier.totalTicks)
        return share * Double(cpus) * 100
    }
}
