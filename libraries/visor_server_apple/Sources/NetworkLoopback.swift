import Network
import VisorServer

/// Listening on loopback with the Network framework: plain TCP, the
/// server's own HTTP and WebSocket framing on top.
public struct NetworkLoopback: LoopbackListening {
    public init() {}

    @MainActor
    public func listen(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any LoopbackListener {
        try NetworkListener(port: port, accept: accept)
    }
}
