/// A container to make: its name, its image, the folders of this computer
/// it sees, its labels, and what of this computer it may use.
public struct ContainerSpec: Sendable, Equatable {
    public var name: String
    public var image: String
    public var mounts: [ContainerMount]
    public var labels: [String: String]
    /// Processors, and memory in bytes; nil for the tool's own default.
    public var cpus: Int?
    public var memory: UInt64?
    /// A disk of its own of this many bytes, at `diskTarget`, where its
    /// builds keep their output (Bazel's, in Visor's image): kept when the
    /// container is made again at another size, gone with it otherwise.
    /// Nil for none: the output on the container's own disk.
    public var disk: UInt64?
    public var diskTarget: String

    /// Where Visor's image keeps Bazel's output (its /etc/bazel.bazelrc).
    public static let buildOutput = "/var/cache/bazel"

    public init(name: String, image: String, mounts: [ContainerMount], labels: [String: String] = [:], cpus: Int? = nil,
                memory: UInt64? = nil, disk: UInt64? = nil, diskTarget: String = ContainerSpec.buildOutput) {
        self.name = name
        self.image = image
        self.mounts = mounts
        self.labels = labels
        self.cpus = cpus
        self.memory = memory
        self.disk = disk
        self.diskTarget = diskTarget
    }
}
