// A Unix socket on the host whose every connection is a TCP stream to a
// port on loopback, opened as `opening` says (a header first, none, or
// refused), then spliced both ways until both ends have ended: what the
// Sessions container's sockets are on the Mac. Two of them, each carried
// into the guest (ContainerBootSpec.Socket):
//
// - HostRelay: the relay, to agent-proxy's relay port, each stream begun
//   with the PROXY v2 header naming the container and proving the relay;
// - the driver link (ContainerEngine.driverLink), to Visor's driver
//   (agent_protocol's AgentDriver, 127.0.0.1:7434), with no header: the
//   agents' JWTs say who they are.
//
// One thread a connection, at most `maxConnections` at once (more are
// closed at once, and that's logged once a burst).

import CAgentProxyPOSIX
import Foundation
import Synchronization
import VisorAgentProxy

public final class UnixBridge: Sendable {
    /// How a connection's stream to the port begins.
    public enum Opening: Sendable, Equatable {
        /// The guest's bytes alone.
        case plain
        /// These bytes first.
        case header([UInt8])
        /// None: the guest's connection closed, and why logged.
        case refused(String)
    }

    public static let defaultMaxConnections = 256

    /// What it's called in the log (`relay`, `driver link`).
    public let name: String
    /// What's at the port, for the log (`agent-proxy`, `Visor's driver`).
    public let target: String
    public let socketPath: String
    public let host: String
    public let port: Int
    public let maxConnections: Int
    private let opening: @Sendable () -> Opening
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    private struct State {
        var listener: Int32 = -1
        var stopped = false
        var open = 0
        var refusedSinceLogged = 0
    }

    public init(name: String, target: String, socketPath: String, host: String = "127.0.0.1", port: Int,
                maxConnections: Int = UnixBridge.defaultMaxConnections, opening: @escaping @Sendable () -> Opening,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.name = name
        self.target = target
        self.socketPath = socketPath
        self.host = host
        self.port = port
        self.maxConnections = max(maxConnections, 1)
        self.opening = opening
        self.log = log
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
        log("\(name): \(socketPath) to \(target) at \(host):\(port)")
        Thread.detachNewThread { [self] in
            // The listener is this thread's to close, not stop()'s: closed
            // there, its descriptor's number could be another socket's (a
            // listener's elsewhere in the process) by the time this thread
            // calls accept on it again, or for the first time, and that
            // socket's connections would be taken here.
            defer { close(listener) }
            while true {
                let client = agent_proxy_accept(listener)
                if client < 0 { return }
                if state.withLock({ $0.stopped }) {
                    close(client)
                    return
                }
                guard admit() else {
                    close(client)
                    continue
                }
                Thread.detachNewThread { [self] in
                    carry(client)
                    state.withLock { $0.open -= 1 }
                }
            }
        }
    }

    /// No more connections taken (those open go on until they end), the
    /// socket file gone. The accept thread is woken to close the listener:
    /// on Linux by its shutdown; on macOS, where a listener isn't shut down,
    /// by a connection of its own.
    public func stop() {
        let listener = state.withLock { state -> Int32 in
            state.stopped = true
            defer { state.listener = -1 }
            return state.listener
        }
        guard listener >= 0 else { return }
        agent_proxy_shutdown(listener)
        let wake = agent_proxy_connect_unix(socketPath)
        if wake >= 0 { close(wake) }
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
            log("\(name): \(maxConnections) connections open: closing more until one ends")
        } else if admitted, let burst {
            log("\(name): \(burst) connection(s) were closed while \(maxConnections) were open")
        }
        return admitted
    }

    /// One connection: the port dialled, its opening sent, then the bytes
    /// both ways until both ends have ended.
    private func carry(_ client: Int32) {
        let first: [UInt8]
        switch opening() {
        case .plain: first = []
        case let .header(bytes): first = bytes
        case let .refused(why):
            log("\(name): \(why): the container's stream closed")
            close(client)
            return
        }
        let upstream = agent_proxy_connect_tcp(host, UInt16(clamping: port))
        guard upstream >= 0 else {
            log("\(name): \(target) at \(host):\(port) didn't answer: the container's stream closed")
            close(client)
            return
        }
        if !first.isEmpty {
            let sent = first.withUnsafeBytes { write(upstream, $0.baseAddress, $0.count) }
            guard sent == first.count else {
                close(upstream)
                close(client)
                return
            }
        }
        Splice.join(client, upstream)
    }
}
