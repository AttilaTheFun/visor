/// Listening for connections on this computer's loopback interface, as the
/// system does it. Both of the server's listeners — the WebSocket and the
/// REST side — take loopback only: the road in from the network fronts
/// them. What is said on a connection is the server's business (HTTP and
/// WebSocket framing are read and written here, the same everywhere).
public protocol LoopbackListening: Sendable {
    /// Listens on `port` of 127.0.0.1; each connection, as it arrives, goes
    /// to `accept` on the main actor. Throws when the port cannot be had.
    @MainActor
    func listen(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any LoopbackListener
}
