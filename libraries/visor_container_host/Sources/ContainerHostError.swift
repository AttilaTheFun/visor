/// A container host's refusal, in words a person can read.
public struct ContainerHostError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
