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

    public init(name: String, image: String, mounts: [ContainerMount], labels: [String: String] = [:], cpus: Int? = nil,
                memory: UInt64? = nil) {
        self.name = name
        self.image = image
        self.mounts = mounts
        self.labels = labels
        self.cpus = cpus
        self.memory = memory
    }
}
