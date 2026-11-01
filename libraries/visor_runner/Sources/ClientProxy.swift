import CVisorPOSIX
import Foundation

/// The Runner's client proxy (docs/co-tenancy.md): a container server's
/// clients reach it at the Mac's addresses and a port of the Runner's, on
/// every interface (IPv4 and IPv6), and each connection goes on to the
/// server where only the Mac reaches it, the bytes both ways as they come
/// (HTTP, the WebSocket). In place of a forwarder of the Mac's own (socat).
public final class ClientProxy: Sendable {
    /// One server's front: the port its clients come to, and where the
    /// server is.
    public struct Front: Codable, Equatable, Sendable {
        /// The server's name, as the Runner knows it.
        public var name: String
        public var port: Int
        /// The server's address and port, as the Mac reaches it.
        public var host: String
        public var hostPort: Int

        public init(name: String, port: Int, host: String, hostPort: Int) {
            self.name = name
            self.port = port
            self.host = host
            self.hostPort = hostPort
        }
    }

    public let front: Front
    private let listeners: [Int32]

    /// Listening at the front's port, IPv4 and IPv6 (either is enough).
    /// Nil when neither can be had.
    public init?(front: Front) {
        guard (1...65535).contains(front.port) else { return nil }
        visor_ignore_broken_pipes()
        listeners = [visor_listen(UInt16(front.port), 1), visor_listen6(UInt16(front.port))].filter { $0 >= 0 }
        guard !listeners.isEmpty else { return nil }
        self.front = front
    }

    public func start() {
        for listener in listeners {
            Thread.detachNewThread { [self] in
                while true {
                    let client = visor_accept(listener)
                    if client < 0 { return }
                    Thread.detachNewThread { [self] in carry(client) }
                }
            }
        }
    }

    public func stop() {
        for listener in listeners {
            visor_shutdown(listener)
            close(listener)
        }
    }

    /// One client's connection, to the server and back, until both ways
    /// have ended. When one way ends the other is given a few seconds to
    /// end too (an answer still on its way), then both are ended.
    private func carry(_ client: Int32) {
        let server = visor_connect_tcp(front.host, UInt16(clamping: front.hostPort))
        guard server >= 0 else {
            close(client)
            return
        }
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.pump(from: client, to: server)
            ended.signal()
        }
        Thread.detachNewThread {
            Self.pump(from: server, to: client)
            ended.signal()
        }
        ended.wait()
        if ended.wait(timeout: .now() + 5) == .timedOut {
            visor_shutdown(client)
            visor_shutdown(server)
            ended.wait()
        }
        close(client)
        close(server)
    }

    /// The bytes from one to the other as they come, until the one ends or
    /// the other stops taking them; then the other hears that no more is
    /// coming.
    static func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        reading: while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(sink, $0.baseAddress! + sent, count - sent) }
                if wrote <= 0 { break reading }
                sent += wrote
            }
        }
        visor_shutdown_write(sink)
    }
}
