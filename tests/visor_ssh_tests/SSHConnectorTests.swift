// Connecting for real, to an SSH server played here on 127.0.0.1 (its own
// Ed25519 host key, the one user key it lets in, session and direct-tcpip
// channels, each of the latter glued to a TCP connection on its loopback),
// and a forward through it to an echo server: the bytes come back, and the
// host key handed back is the server's. 0.73.3 trapped at every connect,
// its channel gate made off the connection's event loop (visor#577); none
// of these tests had connected before.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization
@testable import VisorSSH
import XCTest

final class SSHConnectorTests: XCTestCase {
    @MainActor
    func testAForwardCarriesBytesBothWaysAndTheHostKeyIsTheServers() async throws {
        let raw = SSHConnector.newPrivateKey()
        let servers = try await TestServers.start(user: "visor", key: raw)
        let connection = try await within(20, "connect") {
            try await SSHConnector().connect([SSHHop(user: "visor", host: "127.0.0.1", port: servers.sshPort)],
                                             privateKey: raw, hostKeys: [nil])
        }
        XCTAssertEqual(connection.hostKeys, [servers.hostKey.publicKey.openSSHLine], "the server's own key, to keep")
        XCTAssertFalse(connection.hostKeys[0].isEmpty)
        let port = try await within(10, "forward") { try await connection.forward(toPort: servers.echoPort) }
        let sent = Array("through the gate and back".utf8)
        let back = try await within(10, "round trip") { try await roundTrip(to: port, sending: sent) }
        XCTAssertEqual(back, sent)
        connection.close()
        try await servers.stop()
    }

    @MainActor
    func testMoreConnectionsThanTheGateHoldsAllWaitTheirTurnAndGetThrough() async throws {
        let raw = SSHConnector.newPrivateKey()
        let servers = try await TestServers.start(user: "visor", key: raw)
        let connection = try await within(20, "connect") {
            try await SSHConnector().connect([SSHHop(user: "visor", host: "127.0.0.1", port: servers.sshPort)],
                                             privateKey: raw, hostKeys: [nil])
        }
        let port = try await within(10, "forward") { try await connection.forward(toPort: servers.echoPort) }
        // All at once: past the limit a connection waits, unread, for one
        // before it to close, rather than being refused.
        let count = ChannelGate.standardLimit + 4
        let echoed = try await within(30, "\(count) round trips") {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for n in 0..<count {
                    group.addTask {
                        let sent = Array("connection \(n)".utf8)
                        return try await roundTrip(to: port, sending: sent) == sent
                    }
                }
                return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
        }
        XCTAssertEqual(echoed, count, "every one through, none dropped")
        connection.close()
        try await servers.stop()
    }
}

// MARK: - The servers played

/// An SSH server on 127.0.0.1 that lets one user's key in, and an echo
/// server beside it, its direct-tcpip channels' target.
private struct TestServers: Sendable {
    let hostKey: NIOSSHPrivateKey
    let sshPort: Int
    let echoPort: Int
    private let group: MultiThreadedEventLoopGroup
    private let channels: [Channel]

    static func start(user: String, key raw: Data) async throws -> TestServers {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let allowed = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw)).publicKey
        let echo = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Echo()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let ssh = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHServerConfiguration(hostKeys: [hostKey],
                                                               userAuthDelegate: OneKey(user: user, key: allowed))
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .server(configuration), allocator: channel.allocator,
                                      inboundChildChannelInitializer: { child, type in Self.accept(child, type) }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        guard let sshPort = ssh.localAddress?.port, let echoPort = echo.localAddress?.port else {
            throw TestFailure(what: "no port")
        }
        return TestServers(hostKey: hostKey, sshPort: sshPort, echoPort: echoPort, group: group, channels: [ssh, echo])
    }

    /// A session channel (the connector's probe opens and closes one) as
    /// it is; a direct-tcpip channel glued to a connection to its target.
    private static func accept(_ child: Channel, _ type: SSHChannelType) -> EventLoopFuture<Void> {
        switch type {
        case .session:
            return child.eventLoop.makeSucceededVoidFuture()
        case .directTCPIP(let target):
            return ClientBootstrap(group: child.eventLoop)
                .connect(host: target.targetHost, port: target.targetPort)
                .flatMapThrowing { outbound in
                    let (a, b) = Glue.matchedPair()
                    try child.pipeline.syncOperations.addHandlers([SSHWrapper(), a])
                    try outbound.pipeline.syncOperations.addHandler(b)
                }
        default:
            return child.eventLoop.makeFailedFuture(TestFailure(what: "channel \(type)"))
        }
    }

    func stop() async throws {
        for channel in channels { try? await channel.close().get() }
        try await group.shutdownGracefully()
    }
}

/// One user, one Ed25519 key: anything else refused.
private final class OneKey: NIOSSHServerUserAuthenticationDelegate {
    private let user: String
    private let key: NIOSSHPublicKey
    init(user: String, key: NIOSSHPublicKey) {
        self.user = user
        self.key = key
    }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == user, case .publicKey(let offer) = request.request, offer.publicKey == key else {
            return responsePromise.succeed(.failure)
        }
        responsePromise.succeed(.success)
    }
}

/// What it reads, written back.
private final class Echo: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { context.flush() }
}

/// Two channels joined, on one event loop: what one reads the other
/// writes, and a close carried across.
private final class Glue: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    private var partner: Glue?
    private var context: ChannelHandlerContext?

    static func matchedPair() -> (Glue, Glue) {
        let first = Glue(), second = Glue()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.context?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// MARK: - The client's side

/// Connects to `port` on 127.0.0.1, sends `bytes`, and gives back as many
/// read, then closes.
private func roundTrip(to port: Int, sending bytes: [UInt8]) async throws -> [UInt8] {
    let group = MultiThreadedEventLoopGroup.singleton
    let promise = group.next().makePromise(of: [UInt8].self)
    let channel = try await ClientBootstrap(group: promise.futureResult.eventLoop)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(Collector(count: bytes.count, done: promise))
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
    defer { channel.close(promise: nil) }
    try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    return try await promise.futureResult.get()
}

/// The first `count` bytes read; fails if the connection closes first.
private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let count: Int
    private let done: EventLoopPromise<[UInt8]>
    private var read: [UInt8] = []
    private var finished = false
    init(count: Int, done: EventLoopPromise<[UInt8]>) {
        self.count = count
        self.done = done
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        read += unwrapInboundIn(data).readableBytesView
        guard !finished, read.count >= count else { return }
        finished = true
        done.succeed(read)
    }
    func channelInactive(context: ChannelHandlerContext) {
        guard !finished else { return }
        finished = true
        done.fail(TestFailure(what: "closed after \(read.count) of \(count) bytes"))
    }
}

// MARK: - Time

private struct TestFailure: Error, CustomStringConvertible {
    let what: String
    var description: String { what }
}

/// Once, by whichever comes first.
private final class Once: Sendable {
    private let done = Mutex(false)
    func first() -> Bool { done.withLock { done in defer { done = true }; return !done } }
}

/// What `body` gives, or a failure once `seconds` have passed: a hang
/// fails the test rather than holding it.
private func within<T: Sendable>(_ seconds: Int, _ what: String,
                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            if once.first() { continuation.resume(with: result) }
        }
        let work = Task {
            do { finish(.success(try await body())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            finish(.failure(TestFailure(what: "\(what): nothing after \(seconds) s")))
        }
    }
}
