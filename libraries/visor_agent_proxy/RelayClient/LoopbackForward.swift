// `relay-client run --forward <port>=<socket>`: a listener on the
// container's loopback (127.0.0.1:<port>) whose every connection is joined
// to the Unix socket at <socket>, a host's socket carried in. Visor's
// Sessions container carries its driver in so (/run/visor/driver.sock,
// spliced on the Mac to Visor's AgentDriver on 127.0.0.1:7434), and its
// agents' wrappers dial AGENT_DRIVER_URL=http://127.0.0.1:7434, the same
// address as on the Mac.
//
// Loopback is what the nat chain never redirects (ContainerNetwork.excluded),
// so these connections never go to agent-proxy: nothing here depends on its
// relay, and the agents' JWTs, not a PROXY header, say who they are. Nothing
// here reads what goes through.

import CRelayClientPOSIX
import Foundation
import VisorAgentProxy

/// One loopback port forwarded to a Unix socket.
public final class LoopbackForward: Sendable {
    /// What `--forward` says: a port on 127.0.0.1, and the socket it goes to.
    public struct Spec: Equatable, Sendable, CustomStringConvertible {
        public var port: UInt16
        public var socket: String

        public init(port: UInt16, socket: String) {
            self.port = port
            self.socket = socket
        }

        /// `<port>=<socket>`: a port from 1 to 65535 and an absolute path;
        /// nil for anything else.
        public init?(_ text: String) {
            guard let equals = text.firstIndex(of: "="), let port = UInt16(text[..<equals]), port > 0 else { return nil }
            let socket = String(text[text.index(after: equals)...])
            guard socket.hasPrefix("/"), !socket.contains("\0") else { return nil }
            self.init(port: port, socket: socket)
        }

        public var description: String { "127.0.0.1:\(port) to \(socket)" }
    }

    /// Where it listens: loopback, which the chain never redirects.
    public static let address = "127.0.0.1"

    public let port: UInt16
    public let socket: String
    private let listener: Int32
    private let log: @Sendable (String) -> Void

    /// Listening on 127.0.0.1 at `spec.port` (0: one the system picks, for a
    /// test). Nil if the port can't be had.
    public init?(_ spec: Spec, log: @escaping @Sendable (String) -> Void) {
        relay_client_ignore_broken_pipes()
        let listener = relay_client_listen(spec.port, 0)
        guard listener >= 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            close(listener)
            return nil
        }
        port = UInt16(bigEndian: bound.sin_port)
        socket = spec.socket
        self.listener = listener
        self.log = log
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let connection = relay_client_accept(listener)
                if connection < 0 { return }
                Thread.detachNewThread { [self] in carry(connection) }
            }
        }
    }

    public func stop() {
        relay_client_shutdown(listener)
        close(listener)
    }

    private func carry(_ connection: Int32) {
        let upstream = relay_client_connect_unix(socket)
        guard upstream >= 0 else {
            log("forward 127.0.0.1:\(port): \(socket) didn't answer (\(String(cString: strerror(errno)))): the connection closed")
            close(connection)
            return
        }
        Splice.join(connection, upstream)
    }
}
