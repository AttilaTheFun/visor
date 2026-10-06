/// How the server listens: the port, whether the network may reach it or
/// only this computer (something in front of it then), and TLS — or a
/// socket file instead of a port.
public struct ListeningOptions: Sendable, Equatable {
    public var port: UInt16
    /// Every interface, not loopback alone.
    public var everywhere: Bool
    /// Serve TLS with this identity; nil for plain TCP (a front of your
    /// own terminates TLS, or the road is trusted).
    public var tls: TLSIdentity?
    /// Listen on a Unix domain socket at this path instead of the port,
    /// made so that only this user can open it; a stale file there is
    /// replaced. Systems without them throw `ListeningError.unixUnavailable`.
    public var unixPath: String?

    public init(port: UInt16, everywhere: Bool = false, tls: TLSIdentity? = nil, unixPath: String? = nil) {
        self.port = port
        self.everywhere = everywhere
        self.tls = tls
        self.unixPath = unixPath
    }
}
