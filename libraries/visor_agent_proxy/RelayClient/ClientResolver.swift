// relay-client's resolver, on 127.0.0.1:53 in the container: a name's
// A query is answered with a fake address (FakeAddresses), so a connection
// to it carries the name to agent-proxy; AAAA and HTTPS/SVCB queries have no
// answer, so programs use IPv4 and don't take real addresses from hints;
// anything else (MX, TXT, SRV, PTR…) is asked of agent-proxy's resolver over
// the relay.

import Foundation
import VisorAgentProxy

/// The container's resolver.
public struct ClientResolver: DNSAnswering {
    /// How long an answer is kept: short, though a name keeps its address
    /// until 131,070 others have been given one.
    public static let ttl: UInt32 = 60

    public let addresses: FakeAddresses
    /// Asks agent-proxy (the relay's DoH): the answer's bytes, or nil.
    public let ask: @Sendable ([UInt8]) -> [UInt8]?

    public init(addresses: FakeAddresses, ask: @escaping @Sendable ([UInt8]) -> [UInt8]?) {
        self.addresses = addresses
        self.ask = ask
    }

    public init(addresses: FakeAddresses, relay: RelayDialer) {
        self.init(addresses: addresses, ask: { relay.query($0) })
    }

    public func answer(_ query: DNSMessage) async -> DNSMessage? {
        guard !query.isResponse else { return nil }
        switch query.type {
        case 1 where query.name == "localhost" || query.name.hasSuffix(".localhost"):
            return query.answer(ipv4: [127, 0, 0, 1], ttl: Self.ttl)
        case 1 where !query.name.isEmpty:
            return query.answer(ipv4: addresses.address(for: query.name), ttl: Self.ttl)
        case 28, 64, 65:
            return query.answer(.noError)
        default:
            let ask = self.ask
            let bytes = query.bytes
            // Asked on a thread of its own: the relay's socket blocks.
            let answer = await withCheckedContinuation { (done: CheckedContinuation<[UInt8]?, Never>) in
                Thread.detachNewThread { done.resume(returning: ask(bytes)) }
            }
            guard let answer, let message = DNSMessage(answer), message.isResponse else { return query.answer(.serverFailure) }
            return message.with(id: query.id)
        }
    }
}
