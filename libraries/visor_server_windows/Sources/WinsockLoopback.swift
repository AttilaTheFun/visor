import VisorServer

/// Listening on loopback with Winsock.
public struct WinsockLoopback: LoopbackListening {
    public init() {}

    @MainActor
    public func listen(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any LoopbackListener {
        try WinsockListener(port: port, accept: accept)
    }
}
