/// Listening for connections, as the system does it. One listener takes
/// everything — the live channel and the REST side — on one port: on
/// loopback alone, or on every interface for the network to reach; plain,
/// or over TLS where the system can serve it. What is said on a connection
/// is the server's business (HTTP and WebSocket framing are read and
/// written there, the same everywhere).
public protocol Listening: Sendable {
    /// Listens as `options` say; each connection, as it arrives, goes to
    /// `accept` on the main actor. Throws when the port cannot be had, or
    /// TLS was asked for where the system cannot serve it.
    @MainActor
    func listen(_ options: ListeningOptions, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any Listener
    /// Whether another server listens at the socket file `path` now: one
    /// already there is left alone rather than replaced (a second server
    /// on the computer — a headless one, a test — would otherwise take the
    /// installed server's SSH clients and leave them a dead file).
    func answers(unixPath path: String) -> Bool
}

public extension Listening {
    func answers(unixPath path: String) -> Bool { false }
}
