/// What a server says of itself at sign-in: its id on the network of
/// computers, and the addresses it can be reached at (as clients read
/// them). A server from before ids says neither.
public struct ServerIdentity: Equatable, Sendable {
    public var id: String
    public var addresses: [String]
    /// The server's own SSH public key line, "" for none.
    public var sshKey: String

    public init(id: String, addresses: [String], sshKey: String = "") {
        self.id = id
        self.addresses = addresses
        self.sshKey = sshKey
    }
}
