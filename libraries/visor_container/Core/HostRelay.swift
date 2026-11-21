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
// One thread a connection, at most `maxConnections` at once (more are
// closed at once, and that's logged once a burst). No token, or no
// agent-proxy answering: the connection is closed, and the guest's egress
// check fails.

import CAgentProxyPOSIX
import Foundation
import Synchronization
import VisorAgentProxy

public final class HostRelay: Sendable {
    /// The lease id the header names the container by (TLV 0xE1).
    public static let lease = "visor-sessions"
    /// Where the guest finds it.
    public static let guestPath = "/run/agent-proxy/relay.sock"
    public static let defaultMaxConnections = 256

    public let socketPath: String
    public let host: String
    public let port: Int
    public let maxConnections: Int
    private let token: @Sendable () -> String?
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    private struct State {
        var listener: Int32 = -1
        var stopped = false
        var open = 0
        var refusedSinceLogged = 0
    }

    /// `token` is the relay's token as it is now (nil or empty: none, and
    /// every connection is closed).
    public init(socketPath: String, host: String = "127.0.0.1", port: Int, maxConnections: Int = HostRelay.defaultMaxConnections,
                token: @escaping @Sendable () -> String?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.host = host
        self.port = port
        self.maxConnections = max(maxConnections, 1)
        self.token = token
        self.log = log
    }

    /// The header each relayed stream starts with.
    public static func header(token: String) -> [UInt8] {
        ProxyProtocolHeader.relayed(lease: lease, relayToken: token).encoded()
    }

    /// Listening at `socketPath` (its folder made, this user's alone; a
    /// socket left there replaced), accepting in the background. Throws
    /// when it can't listen.
    public func start() throws {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        agent_proxy_ignore_broken_pipes()
        let listener = agent_proxy_listen_unix(socketPath)
        guard listener >= 0 else { throw HostRelayError(path: socketPath, errno: errno) }
        let taken = state.withLock { state -> Bool in
            guard !state.stopped, state.listener < 0 else { return false }
            state.listener = listener
            return true
        }
        guard taken else {
            close(listener)
            throw HostRelayError(path: socketPath, errno: EALREADY)
        }
        log("relay: \(socketPath) to agent-proxy at \(host):\(port)")
        Thread.detachNewThread { [self] in
            while true {
                let client = agent_proxy_accept(listener)
                if client < 0 { return }
                guard admit() else {
                    close(client)
                    continue
                }
                Thread.detachNewThread { [self] in
                    relay(client)
                    state.withLock { $0.open -= 1 }
                }
            }
        }
    }

    /// No more connections taken (those open go on until they end), the
    /// socket file gone.
    public func stop() {
        let listener = state.withLock { state -> Int32 in
            state.stopped = true
            defer { state.listener = -1 }
            return state.listener
        }
        guard listener >= 0 else { return }
        agent_proxy_shutdown(listener)
        close(listener)
        unlink(socketPath)
    }

    /// The connections being carried now.
    public var openConnections: Int { state.withLock { $0.open } }

    /// Room for another connection, counted; else the refusal logged once a burst.
    private func admit() -> Bool {
        let (admitted, burst) = state.withLock { state -> (Bool, Int?) in
            if state.open < maxConnections {
                state.open += 1
                let refused = state.refusedSinceLogged
                state.refusedSinceLogged = 0
                return (true, refused > 0 ? refused : nil)
            }
            state.refusedSinceLogged += 1
            return (false, state.refusedSinceLogged == 1 ? 1 : nil)
        }
        if !admitted, burst != nil {
            log("relay: \(maxConnections) connections open: closing more until one ends")
        } else if admitted, let burst {
            log("relay: \(burst) connection(s) were closed while \(maxConnections) were open")
        }
        return admitted
    }

    /// One connection: agent-proxy dialled, the header sent, then the bytes
    /// both ways until both ends have ended.
    private func relay(_ client: Int32) {
        guard let token = token(), !token.isEmpty else {
            log("relay: no relay token (agent-proxy/relay-token): the container's stream closed")
            close(client)
            return
        }
        let upstream = agent_proxy_connect_tcp(host, UInt16(clamping: port))
        guard upstream >= 0 else {
            log("relay: agent-proxy at \(host):\(port) didn't answer: the container's stream closed")
            close(client)
            return
        }
        let header = Self.header(token: token)
        let sent = header.withUnsafeBytes { write(upstream, $0.baseAddress, $0.count) }
        guard sent == header.count else {
            close(upstream)
            close(client)
            return
        }
        Splice.join(client, upstream)
    }
}
