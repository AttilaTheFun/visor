/// One end of a relayed message: a session on a server, by their ids, with
/// their names as they were when the message was written.
public struct RelayEndpoint: Codable, Equatable, Hashable, Sendable {
    public var server: String
    public var serverName: String
    public var session: String
    public var sessionName: String

    public init(server: String, serverName: String = "", session: String, sessionName: String = "") {
        self.server = server
        self.serverName = serverName
        self.session = session
        self.sessionName = sessionName
    }
}
