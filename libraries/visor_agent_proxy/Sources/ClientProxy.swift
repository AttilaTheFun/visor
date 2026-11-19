// Moved from MultiPass with the egress proxy (Logan, 2026-11-14), not yet
// started by shireworks-agent-proxy: the fronts, and the watch that starts
// their servers again, come with a later phase.

import CAgentProxyPOSIX
import Foundation

/// The Runner's client proxy (Visor's docs/co-tenancy.md): a container server's
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
        /// What starts the server again when it stops answering (a shell
        /// command line, ServerWatch); nil, and nothing does.
        public var start: String?

        public init(name: String, port: Int, host: String, hostPort: Int, start: String? = nil) {
            self.name = name
            self.port = port
            self.host = host
            self.hostPort = hostPort
            self.start = start
        }
    }

    public let front: Front
    private let listeners: [Int32]

    /// Listening at the front's port, IPv4 and IPv6 (either is enough).
    /// Nil when neither can be had.
    public init?(front: Front) {
        guard (1...65535).contains(front.port) else { return nil }
        agent_proxy_ignore_broken_pipes()
        listeners = [agent_proxy_listen(UInt16(front.port), 1), agent_proxy_listen6(UInt16(front.port))].filter { $0 >= 0 }
        guard !listeners.isEmpty else { return nil }
        self.front = front
    }

    public func start() {
        for listener in listeners {
            Thread.detachNewThread { [self] in
                while true {
                    let client = agent_proxy_accept(listener)
                    if client < 0 { return }
                    Thread.detachNewThread { [self] in carry(client) }
                }
            }
        }
    }

    public func stop() {
        for listener in listeners {
            agent_proxy_shutdown(listener)
            close(listener)
        }
    }

    /// One client's connection, to the server and back, until both ways
    /// have ended. When one way ends the other is given a few seconds to
    /// end too (an answer still on its way), then both are ended.
    private func carry(_ client: Int32) {
        let server = agent_proxy_connect_tcp(front.host, UInt16(clamping: front.hostPort))
        guard server >= 0 else {
            close(client)
            return
        }
        Self.splice(client, server)
    }

    /// Two connections joined, each way, until both have ended (Splice).
    static func splice(_ client: Int32, _ server: Int32) { Splice.join(client, server) }

    /// The bytes from one to the other, until the one ends (Splice).
    static func pump(from source: Int32, to sink: Int32) { Splice.pump(from: source, to: sink) }
}
