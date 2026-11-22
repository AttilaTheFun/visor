// What a ContainerCommand left: its status, what it wrote (its standard
// output and error together), and whether it was ended before it ended.

public struct ContainerCommandOutput: Equatable, Sendable {
    public var status: Int32
    public var text: String
    /// Ended by its `stopping` or its limit.
    public var stopped: Bool

    public init(status: Int32, text: String, stopped: Bool) {
        self.status = status
        self.text = text
        self.stopped = stopped
    }
}
