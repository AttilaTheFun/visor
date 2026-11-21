// The Sessions container's way out, on the host (docs/containers.md; a port
// of Shireworks' ContainerRelay): the container has no network interface,
// only a Unix socket carried in at /run/agent-proxy/relay.sock. This is that
// socket's host end. Each connection the guest opens on it is one here: a
// TCP stream is opened to agent-proxy's relay listener on loopback
// (`relayPort`, in this same server), started with the PROXY v2 header
// naming the container (TLV 0xE1, `visor-sessions`) and proving the relay
// (TLV 0xE2, the relay's token, re-read as its reader says: each minute
// from the server's secrets), and then the bytes are carried both ways
// until both ends have ended. relay-client in the guest sends the guest's
// traffic here; agent-proxy reads the header, then the guest's request (a
// CONNECT, DNS over HTTPS, or `GET /`, its health).
//
// The socket itself is a UnixBridge's (the driver link is the other); at
// most `maxConnections` at once. No token, or no agent-proxy answering: the
// connection is closed, and the guest's egress check fails.

import Foundation
import VisorAgentProxy

public final class HostRelay: Sendable {
    /// The lease id the header names the container by (TLV 0xE1).
    public static let lease = "visor-sessions"
    /// Where the guest finds it.
    public static let guestPath = "/run/agent-proxy/relay.sock"
    public static let defaultMaxConnections = UnixBridge.defaultMaxConnections

    private let bridge: UnixBridge

    public var socketPath: String { bridge.socketPath }
    public var host: String { bridge.host }
    public var port: Int { bridge.port }
    public var maxConnections: Int { bridge.maxConnections }

    /// `token` is the relay's token as it is now (nil or empty: none, and
    /// every connection is closed).
    public init(socketPath: String, host: String = "127.0.0.1", port: Int, maxConnections: Int = HostRelay.defaultMaxConnections,
                token: @escaping @Sendable () -> String?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        bridge = UnixBridge(name: "relay", target: "agent-proxy", socketPath: socketPath, host: host, port: port, maxConnections: maxConnections,
                            opening: {
                                guard let token = token(), !token.isEmpty else { return .refused("no relay token (agent-proxy/relay-token)") }
                                return .header(HostRelay.header(token: token))
                            }, log: log)
    }

    /// The header each relayed stream starts with.
    public static func header(token: String) -> [UInt8] {
        ProxyProtocolHeader.relayed(lease: lease, relayToken: token).encoded()
    }

    /// Listening at `socketPath` (its folder made, this user's alone; a
    /// socket left there replaced), accepting in the background. Throws
    /// when it can't listen.
    public func start() throws { try bridge.start() }

    /// No more connections taken (those open go on until they end), the
    /// socket file gone.
    public func stop() { bridge.stop() }

    /// The connections being carried now.
    public var openConnections: Int { bridge.openConnections }
}
