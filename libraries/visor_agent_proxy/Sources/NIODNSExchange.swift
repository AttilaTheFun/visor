// A query to an upstream resolver over the network: a datagram first, and
// over TCP when the answer comes back truncated (RFC 7766).

import NIOCore
import NIOPosix

/// Asks upstream resolvers over UDP, and over TCP when an answer is
/// truncated, each exchange on a socket of its own.
public struct NIODNSExchange: DNSExchanging {
    private let group: any EventLoopGroup

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    public func exchange(_ query: DNSMessage, with upstream: DNSUpstream, timeout: Duration) async throws -> DNSMessage {
        let address = try SocketAddress(ipAddress: upstream.host, port: upstream.port)
        let answer = try await Self.within(timeout) { try await udp(query, to: address) }
        guard answer.isTruncated else { return answer }
        return try await Self.within(timeout) { try await tcp(query, to: address) }
    }

    /// One datagram out, and the first back that answers it.
    private func udp(_ query: DNSMessage, to address: SocketAddress) async throws -> DNSMessage {
        let local = address.protocol == .inet6 ? "::" : "0.0.0.0"
        let channel = try await DatagramBootstrap(group: group)
            .bind(host: local, port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(AddressedEnvelope(remoteAddress: address, data: ByteBuffer(bytes: query.bytes)))
            for try await envelope in inbound where envelope.remoteAddress == address {
                guard let answer = DNSMessage(Array(envelope.data.readableBytesView)), answer.id == query.id, answer.isResponse else { continue }
                return answer
            }
            throw DNSTimeout()
        }
    }

    /// The query with its two-byte length, and the answer read the same way.
    private func tcp(_ query: DNSMessage, to address: SocketAddress) async throws -> DNSMessage {
        let channel = try await ClientBootstrap(group: group)
            .connect(to: address) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var framed = ByteBuffer()
            framed.writeInteger(UInt16(query.bytes.count))
            framed.writeBytes(query.bytes)
            try await outbound.write(framed)
            var pending = DNSStreamFrames()
            for try await chunk in inbound {
                pending.append(chunk)
                while let bytes = pending.next() {
                    if let answer = DNSMessage(bytes), answer.id == query.id, answer.isResponse { return answer }
                }
            }
            throw DNSTimeout()
        }
    }

    /// `work`'s result, or DNSTimeout once `timeout` has passed.
    static func within<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DNSTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DNSTimeout() }
            return first
        }
    }
}
