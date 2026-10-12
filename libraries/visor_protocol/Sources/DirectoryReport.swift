/// What a client tells each server it is connected to, as part of its
/// heartbeat: who it is (its id and name, and the Visor app it is), and the
/// servers it is connected to with their sessions. A server keeps the last
/// report of each client connected to it: the directory its agents read,
/// and what decides which client carries a message to which server.
public struct DirectoryReport: Codable, Equatable, Sendable {
    public var client: String
    public var clientName: String
    /// The Visor app it is, as installed and running: its version and
    /// build ("0.31 (8)"), and the system it runs on ("iOS", "macOS").
    public var clientVersion: String?
    public var clientPlatform: String?
    public var servers: [DirectoryServer]

    public init(client: String, clientName: String, clientVersion: String? = nil, clientPlatform: String? = nil, servers: [DirectoryServer]) {
        self.client = client
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientPlatform = clientPlatform
        self.servers = servers
    }
}
