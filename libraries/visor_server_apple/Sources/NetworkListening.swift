import Network
import VisorServer

/// Listening with the Network framework: plain TCP, or TLS with a PKCS#12
/// identity; the server's own HTTP and WebSocket framing on top.
public struct NetworkListening: Listening {
    public init() {}

    @MainActor
    public func listen(_ options: ListeningOptions, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any Listener {
        try NetworkListener(options, accept: accept)
    }
}
