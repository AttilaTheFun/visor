import CVisorPOSIX
import Foundation

/// A container server's clients' connections passed on: a port of this
/// computer's, and every connection to it joined to one to the server in
/// the container, the bytes passed both ways as they come (HTTP, the
/// WebSocket alike), until either side closes. On threads of its own.
public final class TCPProxy: Sendable {
    public let port: UInt16
    private let listener: Int32
    /// Where a connection goes, asked for each: the container's address may
    /// change when it is made again.
    private let upstream: @Sendable () -> (host: String, port: UInt16)?

    /// Listening on `port`: on every interface (`everywhere`: the LAN, a
    /// VPN) or on loopback alone. Nil when the port can't be had.
    public init?(port: UInt16, everywhere: Bool, upstream: @escaping @Sendable () -> (host: String, port: UInt16)?) {
        visor_ignore_broken_pipes()
        let listener = visor_listen(port, everywhere ? 1 : 0)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.upstream = upstream
    }

    /// Takes connections until `stop`.
    public func start() {
        let listener = listener, upstream = upstream
        Thread.detachNewThread {
            while true {
                let client = visor_accept(listener)
                if client < 0 { return }
                Thread.detachNewThread { Self.join(client, upstream: upstream) }
            }
        }
    }

    /// Takes no more connections (those open go on to their end).
    public func stop() {
        visor_shutdown(listener)
        close(listener)
    }

    private static func join(_ client: Int32, upstream: @Sendable () -> (host: String, port: UInt16)?) {
        guard let target = upstream() else {
            close(client)
            return
        }
        let server = visor_connect_tcp(target.host, target.port)
        guard server >= 0 else {
            close(client)
            return
        }
        // Each way on a thread; when one ends, both sockets are ended, which
        // wakes the other, and the last one out closes them.
        let ended = Countdown(2) {
            close(client)
            close(server)
        }
        for (from, to) in [(client, server), (server, client)] {
            Thread.detachNewThread {
                pump(from, to)
                visor_shutdown(client)
                visor_shutdown(server)
                ended.done()
            }
        }
    }

    private static func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }
}
