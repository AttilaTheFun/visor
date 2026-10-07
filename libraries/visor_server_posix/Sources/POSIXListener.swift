import CVisorPOSIX
import Foundation
import Synchronization
import VisorServer

/// A listening socket, accepted on by a thread of its own.
@MainActor
final class POSIXListener: Listener {
    private let descriptor: Int32
    private let stopped = StopFlag()
    /// The socket file, when that is what is listened on: removed at stop.
    private let unixPath: String?

    init(port: UInt16, everywhere: Bool, unixPath: String? = nil, accept: @escaping @MainActor (any ByteStream) -> Void) throws {
        let descriptor = unixPath.map { visor_listen_unix($0) } ?? visor_listen(port, everywhere ? 1 : 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "Visor", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "\(unixPath ?? "port \(port)"): \(String(cString: strerror(errno)))"])
        }
        self.descriptor = descriptor
        self.unixPath = unixPath
        let stopped = self.stopped
        let (connections, arrived) = AsyncStream.makeStream(of: Int32.self)
        Thread.detachNewThread {
            while true {
                let connection = visor_accept(descriptor)
                if connection >= 0 {
                    arrived.yield(connection)
                } else if stopped.isSet || (errno != ECONNABORTED && errno != EMFILE && errno != ENFILE) {
                    break
                }
            }
            closeDescriptor(descriptor)
            arrived.finish()
        }
        Task { @MainActor in
            for await connection in connections { accept(POSIXSocketStream(POSIXSocket(connection))) }
        }
    }

    func stop() {
        stopped.set()
        visor_shutdown(descriptor)
        if let unixPath { unlink(unixPath) }
    }
}

/// Whether the listener was stopped, as its accepting thread asks.
private final class StopFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }
}
