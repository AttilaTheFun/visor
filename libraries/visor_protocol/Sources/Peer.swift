/// Another computer's Visor server, as the network knows it: its id, its
/// name, the addresses it can be reached at (as a client reads them:
/// URLs, bare names, `user@host` for its SSH), and its password. What a
/// server keeps of each of its peers, hands to its clients and to its
/// other peers, and what a client that holds two servers gives each of
/// the other. An empty id is a server from before ids, learned on the
/// first contact.
public struct Peer: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var addresses: [String]
    public var password: String

    public init(id: String, name: String, addresses: [String], password: String) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.password = password
    }

    /// The same computer: by id when both have one, else by an address
    /// in common.
    public func isSame(as other: Peer) -> Bool {
        if !id.isEmpty, !other.id.isEmpty { return id == other.id }
        return !Set(addresses).isDisjoint(with: other.addresses)
    }

    /// What `other` says of the same computer, taken in: its id when this
    /// had none, its name, its addresses added, its password when given.
    /// Whether anything changed.
    public mutating func merge(_ other: Peer) -> Bool {
        var changed = false
        if id.isEmpty, !other.id.isEmpty { id = other.id; changed = true }
        if !other.name.isEmpty, other.name != name { name = other.name; changed = true }
        for address in other.addresses where !addresses.contains(address) { addresses.append(address); changed = true }
        if !other.password.isEmpty, other.password != password { password = other.password; changed = true }
        return changed
    }
}
