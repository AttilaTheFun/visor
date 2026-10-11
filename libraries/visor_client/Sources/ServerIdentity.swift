/// What a server says of itself at sign-in: its id, and the addresses it
/// can be reached at (as clients read them). A server from before ids says
/// neither.
public struct ServerIdentity: Equatable, Sendable {
    public var id: String
    public var addresses: [String]
    /// The server stands alone: reached only at the address it was added
    /// at, nothing about it shared (`Envelope.standalone`).
    public var standalone: Bool

    public init(id: String, addresses: [String], standalone: Bool = false) {
        self.id = id
        self.addresses = addresses
        self.standalone = standalone
    }
}
