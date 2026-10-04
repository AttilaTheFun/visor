import VisorServer

/// Listening on loopback with POSIX sockets.
public struct POSIXLoopback: LoopbackListening {
    public init() {}

    @MainActor
    public func listen(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any LoopbackListener {
        try POSIXListener(port: port, accept: accept)
    }
}
