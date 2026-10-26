/// What a session's container is given of its computer: processor cores,
/// memory, and the disk its builds keep their output on. A session that
/// builds something heavy (a Swift toolchain) is given more.
public struct ContainerSize: Codable, Hashable, Sendable {
    public var cpus: Int
    public var memoryBytes: Int64
    public var diskBytes: Int64

    public init(cpus: Int, memoryBytes: Int64, diskBytes: Int64) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }

    public static let gigabyte: Int64 = 1_073_741_824

    /// What a container is given unless asked otherwise: 6 cores, 16 GB of
    /// memory, 128 GB of disk.
    public static let standard = ContainerSize(cpus: 6, memoryBytes: 16 * gigabyte, diskBytes: 128 * gigabyte)
}
