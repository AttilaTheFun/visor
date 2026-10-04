import Network
import VisorServer

/// A Network framework listener, on the main queue: connections are taken
/// as they arrive, in order.
@MainActor
final class NetworkListener: LoopbackListener {
    private let listener: NWListener

    init(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { accept(NetworkStream(connection)) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
    }
}
