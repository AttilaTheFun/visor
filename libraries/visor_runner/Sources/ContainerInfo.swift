/// A container as its backend tells of it.
public struct ContainerInfo: Equatable, Sendable {
    public var name: String
    public var running: Bool
    public var labels: [String: String]
    /// Its address on the Runner's network for containers, where this
    /// computer reaches it.
    public var address: String?

    public init(name: String, running: Bool, labels: [String: String] = [:], address: String? = nil) {
        self.name = name
        self.running = running
        self.labels = labels
        self.address = address
    }
}
