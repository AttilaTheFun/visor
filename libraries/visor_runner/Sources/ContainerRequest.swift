/// A container to make (ContainerBackend.create): its image, its size, its
/// volumes (kept apart from it, so it can be made again as it was), this
/// computer's folders it sees, and its labels.
public struct ContainerRequest: Equatable, Sendable {
    public var name: String
    public var image: String
    public var cpus: Int?
    public var memoryBytes: Int64?
    public var volumes: [Volume] = []
    public var mounts: [Mount] = []
    public var labels: [String: String] = [:]
    /// x86_64 Linux programs run too, where the Mac has Rosetta.
    public var rosetta = false

    public struct Volume: Equatable, Sendable {
        public var name: String
        public var destination: String
        public var sizeBytes: Int64

        public init(name: String, destination: String, sizeBytes: Int64) {
            self.name = name
            self.destination = destination
            self.sizeBytes = sizeBytes
        }
    }

    public struct Mount: Equatable, Sendable {
        public var source: String
        public var destination: String
        public var readOnly: Bool

        public init(source: String, destination: String, readOnly: Bool) {
            self.source = source
            self.destination = destination
            self.readOnly = readOnly
        }
    }

    public init(name: String, image: String) {
        self.name = name
        self.image = image
    }
}
