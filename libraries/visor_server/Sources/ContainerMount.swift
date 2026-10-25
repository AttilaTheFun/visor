/// A folder of this computer seen in a container: at `target` there, and
/// written to unless `readOnly`.
public struct ContainerMount: Sendable, Equatable {
    public var source: String
    public var target: String
    public var readOnly: Bool

    public init(source: String, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }
}
