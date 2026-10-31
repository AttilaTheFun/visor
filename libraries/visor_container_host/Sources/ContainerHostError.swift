/// A container host's refusal, in words a person can read.
struct ContainerHostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
