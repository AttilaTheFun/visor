// SSH with swift-nio-ssh: this device's Ed25519 key (made once, kept with
// the secrets), a connection as a user, the computer's host key kept and
// compared (trust on first use), and a port on the computer's loopback
// reached from a port here through a direct-tcpip channel per connection.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

@MainActor
public final class NativeVisorSSHService: VisorSSHService {
    private static let keySetting = "ssh.key"
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init() {}

    /// The device's key: read from the secrets, made and kept the first time.
    private func privateKey() -> Curve25519.Signing.PrivateKey {
        if let kept = VisorHost.settings?.secret(key: Self.keySetting), let data = Data(base64Encoded: kept),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        VisorHost.settings?.setSecret(key: Self.keySetting, value: key.rawRepresentation.base64EncodedString())
        return key
    }

    public func publicKey() -> String {
        NIOSSHPrivateKey(ed25519Key: privateKey()).publicKey.openSSHRepresentation + " visor"
    }

    public func connect(user: String, host: String, port: Int, hostKey: String?) async throws -> any VisorSSHSession {
        let key = NIOSSHPrivateKey(ed25519Key: privateKey())
        let seen = SSHOutcome(expected: hostKey)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(role: .client(.init(userAuthDelegate: KeyAuthenticator(user: user, key: key, channel: channel, outcome: seen),
                                                                     serverAuthDelegate: HostKeyChecker(channel: channel, outcome: seen))),
                                                allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(10))
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw VisorSSHError.unreachable(String(describing: error))
        }
        let handler = try await channel.eventLoop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self), eventLoop: channel.eventLoop)
        }.get()
        // Authentication is done when a session's first channel opens;
        // one is asked for now, so a refused key is known at once.
        do {
            try await Self.probe(handler, on: channel)
        } catch {
            try? await channel.close().get()
            if let refusal = seen.failure { throw refusal }
            throw VisorSSHError.keyRefused
        }
        guard let hostKeyLine = seen.hostKey else { throw VisorSSHError.keyRefused }
        return NativeVisorSSHSession(channel: channel, handler: handler, hostKey: hostKeyLine, group: group)
    }

    /// Opens and closes a session channel: the server answers only once
    /// the user is authenticated.
    private static func probe(_ handler: NIOLoopBound<NIOSSHHandler>, on channel: Channel) async throws {
        let child = try await channel.eventLoop.flatSubmit {
            let opened = channel.eventLoop.makePromise(of: Channel.self)
            handler.value.createChannel(opened, channelType: .session) { child, _ in child.eventLoop.makeSucceededFuture(()) }
            return opened.futureResult
        }.get()
        try await child.close().get()
    }
}

/// What the connection's handshake found, written from the event loop
/// and read once it is over: the host key seen, and what was refused.
final class SSHOutcome: Sendable {
    private struct State { var seen: String?; var failure: VisorSSHError? }
    private let expected: String?
    private let state = Mutex(State())
    init(expected: String?) { self.expected = expected }
    /// Takes the host key seen: whether it is the expected one (or none was).
    func take(_ key: String) -> Bool {
        state.withLock { state in
            state.seen = key
            if let expected, expected != key { state.failure = .hostKeyChanged; return false }
            return true
        }
    }
    func refuseKey() { state.withLock { $0.failure = .keyRefused } }
    var hostKey: String? { state.withLock { $0.seen } }
    var failure: VisorSSHError? { state.withLock { $0.failure } }
}

/// Trust on first use: the key seen is kept; a different one is refused,
/// and the connection closed here (NIOSSH would otherwise hold it).
private final class HostKeyChecker: NIOSSHClientServerAuthenticationDelegate {
    private let channel: Channel
    private let outcome: SSHOutcome
    init(channel: Channel, outcome: SSHOutcome) {
        self.channel = channel
        self.outcome = outcome
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if outcome.take(hostKey.openSSHRepresentation) { return validationCompletePromise.succeed(()) }
        validationCompletePromise.fail(VisorSSHError.hostKeyChanged)
        channel.close(promise: nil)
    }
}

/// Offers the device's key once. Asked again, the key was refused: the
/// connection is closed here, as NIOSSH left without methods would
/// otherwise hold it until the server's grace time ran out.
private final class KeyAuthenticator: NIOSSHClientUserAuthenticationDelegate {
    private let user: String
    private let key: NIOSSHPrivateKey
    private let channel: Channel
    private let outcome: SSHOutcome
    private var offered = false
    init(user: String, key: NIOSSHPrivateKey, channel: Channel, outcome: SSHOutcome) {
        self.user = user
        self.key = key
        self.channel = channel
        self.outcome = outcome
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !offered else {
            outcome.refuseKey()
            nextChallengePromise.succeed(nil)
            channel.close(promise: nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
