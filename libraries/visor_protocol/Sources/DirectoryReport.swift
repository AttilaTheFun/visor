/// What a client tells each server it is connected to, as part of its
/// heartbeat: who it is (its id and name), and the servers it is connected
/// to with their sessions. A server keeps the last report of each client
/// connected to it: the directory its agents read, and what decides which
/// client carries a message to which server.
public struct DirectoryReport: Codable, Equatable, Sendable {
    public var client: String
    public var clientName: String
    public var servers: [DirectoryServer]

    public init(client: String, clientName: String, servers: [DirectoryServer]) {
        self.client = client
        self.clientName = clientName
        self.servers = servers
    }
}
