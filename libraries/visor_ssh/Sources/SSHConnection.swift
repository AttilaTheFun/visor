// One SSH connection, to the last hop of its route: a listener on
// 127.0.0.1 whose every connection becomes a channel to the computer — a
// direct-tcpip channel to a port on its loopback, or a session channel
// running a command there — the two glued together. Closing the first
// hop's connection closes everything run through it.

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

@MainActor
public final class SSHConnection {
    /// Each hop's host key, as a line to keep and compare next time.
    public let hostKeys: [String]
    private let root: Channel
    private let handler: NIOLoopBound<NIOSSHHandler>
    private let group: MultiThreadedEventLoopGroup
    private var listeners: [Channel] = []

    init(root: Channel, handler: NIOLoopBound<NIOSSHHandler>, hostKeys: [String], group: MultiThreadedEventLoopGroup) {
        self.root = root
        self.handler = handler
        self.hostKeys = hostKeys
        self.group = group
    }

    /// Reaches `port` on the computer's loopback through a port here, on
    /// 127.0.0.1: the port, for as long as the connection is open.
    public func forward(toPort port: Int) async throws -> Int {
        try await listen { local in
            let originator: SocketAddress
            do { originator = try local.remoteAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0) } catch { return .failure(error) }
            return .success((.directTCPIP(SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: port, originatorAddress: originator)), nil))
        }
    }

    /// Runs `command` on the computer for each connection to a port here,
    /// on 127.0.0.1, the connection's bytes being the command's input and
    /// output: the port, for as long as the connection is open.
    public func attach(command: String) async throws -> Int {
        try await listen { _ in .success((.session, command)) }
    }

    /// A port here whose every connection becomes a channel of the kind
    /// `plan` says (a command run, for a session channel), the two glued.
    private func listen(_ plan: @escaping @Sendable (Channel) -> Result<(SSHChannelType, String?), Error>) async throws -> Int {
        let handler = self.handler
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                let opened = local.eventLoop.makePromise(of: Channel.self)
                let kind: SSHChannelType
                let command: String?
                switch plan(local) {
                case .success(let planned): (kind, command) = planned
                case .failure(let error): return local.eventLoop.makeFailedFuture(error)
                }
                handler.value.createChannel(opened, channelType: kind) { remote, _ in
                    remote.eventLoop.makeCompletedFuture {
                        let (a, b) = GlueHandler.matchedPair()
                        var handlers: [ChannelHandler] = [SSHWrapper()]
                        if let command { handlers.append(ExecStarter(command: command)) }
                        handlers.append(a)
                        try remote.pipeline.syncOperations.addHandlers(handlers)
                        try local.pipeline.syncOperations.addHandler(b)
                    }
                }
                return opened.futureResult.map { _ in }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        listeners.append(listener)
        guard let bound = listener.localAddress?.port else { throw SSHError.unreachable("no port") }
        return bound
    }

    public func close() {
        for listener in listeners { listener.close(promise: nil) }
        listeners = []
        root.close(promise: nil)
    }
}

/// Asks a session channel to run a command, once the channel is up; a
/// refusal closes it (and with it the connection glued to it).
private final class ExecStarter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let command: String
    init(command: String) { self.command = command }

    func channelActive(context: ChannelHandlerContext) {
        let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).whenFailure { _ in
            loopBound.value.close(promise: nil)
        }
        context.fireChannelActive()
    }
}

/// Two channels joined: what one reads the other writes, with back
/// pressure, EOF and closing carried across (after swift-nio-ssh's example).
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }
    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}
