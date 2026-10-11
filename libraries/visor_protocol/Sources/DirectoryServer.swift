/// A server as a client reports it: the server's own id and name (as the
/// server calls itself, not as the client named it), and its sessions.
public struct DirectoryServer: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var sessions: [DirectorySession]

    public init(id: String, name: String, sessions: [DirectorySession] = []) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }
}
