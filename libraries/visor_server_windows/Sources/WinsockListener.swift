import Foundation
import Synchronization
import VisorServer
import WinSDK

/// A listening socket, accepted on by a thread of its own.
@MainActor
final class WinsockListener: LoopbackListener {
    private let handle: SOCKET

    init(port: UInt16, accept: @escaping @MainActor (any ByteStream) -> Void) throws {
        let listening = listenOnLoopback(port)
        guard let handle = listening.socket else {
            throw NSError(domain: "Visor", code: Int(listening.error), userInfo: [NSLocalizedDescriptionKey: "port \(port): Winsock error \(listening.error)"])
        }
        self.handle = handle
        let (connections, arrived) = AsyncStream.makeStream(of: SOCKET.self)
        Thread.detachNewThread {
            while let connection = acceptConnection(handle) { arrived.yield(connection) }
            arrived.finish()
        }
        Task { @MainActor in
            for await connection in connections { accept(WinsockStream(WinsockSocket(connection))) }
        }
    }

    /// Closing the socket wakes its accepting thread, which then ends.
    func stop() {
        closeSocket(handle)
    }
}
