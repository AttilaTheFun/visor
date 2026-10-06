/// What a server says of itself at sign-in: its id on the network of
/// computers, and the addresses it can be reached at (as clients read
/// them). A server from before ids says neither.
public struct ServerIdentity: Equatable, Sendable {
    public var id: String
    public var addresses: [String]

    public init(id: String, addresses: [String]) {
        self.id = id
        self.addresses = addresses
    }
}
