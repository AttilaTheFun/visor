import VisorServer

/// Listening with POSIX sockets: plain TCP, on loopback or every
/// interface. TLS is not served here: a front of your own does.
public struct POSIXListening: Listening {
    public init() {}

    @MainActor
    public func listen(_ options: ListeningOptions, accept: @escaping @MainActor (any ByteStream) -> Void) throws -> any Listener {
        guard options.tls == nil else { throw ListeningError.tlsUnavailable }
        return try POSIXListener(port: options.port, everywhere: options.everywhere, accept: accept)
    }
}
