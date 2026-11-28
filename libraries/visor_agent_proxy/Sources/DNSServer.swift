// The resolver, listening: UDP and TCP on each address it is given, each
// query answered by the forwarder. macOS lets an ordinary user listen on
// port 53. Moved from MultiPassBase (Logan, 2026-11-14); the agent proxy
// answers containers by DNS over HTTPS through the relay (RelayListener),
// and starts none yet. Discarding task groups are macOS 14's, above this
// package's floor.

import Foundation
import NIOCore
import NIOPosix

/// The resolver containers and agents are pointed at.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class DNSServer: Sendable {
    private let forwarder: any DNSAnswering
    private let group: any EventLoopGroup
    private let udp: [NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>]
    private let tcp: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>]

    /// Where it listens: one address and port per UDP and TCP listener, in
    /// the order given (a port given as 0 is the one the system chose).
    public let addresses: [SocketAddress]

    /// Listening on each of `hosts` at `port`, UDP and TCP alike. Throws if
    /// any can't be had (the port taken, an address not this computer's).
    public init(hosts: [String], port: Int, forwarder: any DNSAnswering,
                group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws {
        var udp: [NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>] = []
        var tcp: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>] = []
        var addresses: [SocketAddress] = []
        // A listener that can't be had: those made already are closed before
        // the error goes on (dropped open, NIO's writers trap).
        do {
            for host in hosts {
                var tries = 0
                while true {
                    let datagrams = try await DatagramBootstrap(group: group)
                        .channelOption(.socketOption(.so_reuseaddr), value: 1)
                        .bind(host: host, port: port) { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
                            }
                        }
                    udp.append(datagrams)
                    // TCP on the same port as UDP's, the one the system chose
                    // included. A port the system chose for UDP can be another
                    // socket's for TCP: then another pair, a few times.
                    let bound = datagrams.channel.localAddress?.port ?? port
                    let streams: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
                    do {
                        streams = try await ServerBootstrap(group: group)
                            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                            .bind(host: host, port: bound) { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                                }
                            }
                    } catch let error as IOError where port == 0 && error.errnoCode == EADDRINUSE && tries < 8 {
                        udp.removeLast()
                        try? await datagrams.executeThenClose { _, _ in }
                        tries += 1
                        continue
                    }
                    tcp.append(streams)
                    if let address = datagrams.channel.localAddress { addresses.append(address) }
                    break
                }
            }
        } catch {
            for channel in udp { try? await channel.executeThenClose { _, _ in } }
            for channel in tcp { try? await channel.executeThenClose { _ in } }
            throw error
        }
        self.udp = udp
        self.tcp = tcp
        self.addresses = addresses
        self.forwarder = forwarder
        self.group = group
    }

    /// A server dropped without run() or close() (its owner threw before
    /// serving, say): its listeners closed here, each kept until NIO has
    /// closed it and finished its writer. Dropped open, NIO's writers trap.
    deinit {
        for channel in udp {
            channel.channel.close(promise: nil)
            channel.channel.closeFuture.whenComplete { _ in withExtendedLifetime(channel) {} }
        }
        for channel in tcp {
            channel.channel.close(promise: nil)
            channel.channel.closeFuture.whenComplete { _ in withExtendedLifetime(channel) {} }
        }
    }

    /// Answers until the listeners close (close()).
    public func run() async {
        await withDiscardingTaskGroup { group in
            for channel in udp {
                group.addTask { [forwarder] in await Self.serveDatagrams(channel, forwarder) }
            }
            for channel in tcp {
                group.addTask { [forwarder] in await Self.serveStreams(channel, forwarder) }
            }
        }
    }

    /// Stops listening; run() returns once every listener has closed.
    public func close() async {
        for channel in udp { try? await channel.channel.close() }
        for channel in tcp { try? await channel.channel.close() }
    }

    /// Each datagram answered on its own task, so a slow upstream holds up
    /// no other query.
    private static func serveDatagrams(_ channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>,
                                       _ forwarder: any DNSAnswering) async {
        try? await channel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await envelope in inbound {
                    guard let query = DNSMessage(Array(envelope.data.readableBytesView)) else { continue }
                    let from = envelope.remoteAddress
                    group.addTask {
                        guard let answer = await forwarder.answer(query) else { return }
                        try? await outbound.write(AddressedEnvelope(remoteAddress: from, data: ByteBuffer(bytes: answer.bytes)))
                    }
                }
            }
        }
    }

    /// Each connection on its own task, its queries answered in turn.
    private static func serveStreams(_ channel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
                                     _ forwarder: any DNSAnswering) async {
        try? await channel.executeThenClose { connections in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in connections {
                    group.addTask { await serveConnection(connection, forwarder) }
                }
            }
        }
    }

    private static func serveConnection(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>, _ forwarder: any DNSAnswering) async {
        try? await connection.executeThenClose { inbound, outbound in
            var frames = DNSStreamFrames()
            for try await chunk in inbound {
                frames.append(chunk)
                while let bytes = frames.next() {
                    guard let query = DNSMessage(bytes), let answer = await forwarder.answer(query) else { continue }
                    var framed = ByteBuffer()
                    framed.writeInteger(UInt16(answer.bytes.count))
                    framed.writeBytes(answer.bytes)
                    try await outbound.write(framed)
                }
            }
        }
    }
}
