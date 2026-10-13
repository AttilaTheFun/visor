/// A server as a client reports it: the server's own id and name (as the
/// server calls itself, not as the client named it), the Visor Server it
/// runs, and its sessions.
public struct DirectoryServer: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Its version and build, as it said at the client's sign-in
    /// ("0.31 (8)"); nil from a server that does not say.
    public var version: String?
    public var sessions: [DirectorySession]

    public init(id: String, name: String, version: String? = nil, sessions: [DirectorySession] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.sessions = sessions
    }
}
