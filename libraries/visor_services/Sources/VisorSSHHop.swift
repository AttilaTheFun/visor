/// One SSH server to connect to: as a user, at a host and port.
public struct VisorSSHHop: Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int

    public init(user: String, host: String, port: Int) {
        self.user = user
        self.host = host
        self.port = port
    }
}
