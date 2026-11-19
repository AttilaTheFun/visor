// The header Shireworks' relay starts each container's stream with: PROXY
// protocol version 2 (HAProxy's binary form), whose TLVs say which container
// the stream is from (0xE1, its lease id) and prove the relay (0xE2, its
// token). Visor's docs/server-proxy.md, "Containers: no network"; the
// relay's side is OSSServer's ContainerRelay (ProxyV2). Read whole before
// anything else on the stream; the relay listener takes nothing without it.
// Moved from MultiPass (Logan, 2026-11-14).

import CAgentProxyPOSIX
import Foundation

/// A PROXY protocol v2 header, as the agent proxy's relay listener reads it.
public struct ProxyProtocolHeader: Equatable, Sendable {
    public enum Command: UInt8, Sendable {
        /// The relay's own connection (a health check): no addresses.
        case local = 0
        /// A connection relayed on behalf of a container.
        case proxy = 1
    }

    /// Why a header couldn't be read.
    public enum Problem: Error, Equatable {
        case notProxyProtocol
        case unsupportedVersion(UInt8)
        case unknownCommand(UInt8)
        case truncated
        case badTLV
    }

    public var command: Command
    /// The address family and protocol byte, as sent (0x11 TCP over IPv4,
    /// 0x21 over IPv6, 0x31 a Unix stream, 0x00 unspecified).
    public var family: UInt8
    /// The address block, as sent (its meaning depends on `family`); the
    /// relay's addresses mean little here, a container having none.
    public var addresses: [UInt8]
    /// The TLVs, by type; a type sent twice keeps the last.
    public var tlvs: [UInt8: [UInt8]]

    /// The custom TLV types the relay listener reads (PP2_TYPE_MIN_CUSTOM is 0xE0).
    public static let leaseIDType: UInt8 = 0xE1
    public static let relayTokenType: UInt8 = 0xE2

    static let signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]

    /// The container's lease id (TLV 0xE1), as text.
    public var leaseID: String? { tlvs[Self.leaseIDType].map { String(decoding: $0, as: UTF8.self) } }

    /// Whether `lease` is a lease id as Shireworks makes them: letters,
    /// digits and hyphens, 1 to 64 of them. It goes into log lines and a
    /// forward's client header, so nothing else (a CR or LF least of all)
    /// is taken (NCH's review of #414).
    public static func isLeaseID(_ lease: String) -> Bool {
        (1...64).contains(lease.utf8.count) && lease.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D
        }
    }

    /// Whether the header carries the relay's token `token` (TLV 0xE2),
    /// compared in constant time; never for an empty expected token (no
    /// relay set up: nothing is let in).
    public func carriesRelayToken(_ token: String) -> Bool {
        guard !token.isEmpty, command == .proxy, let given = tlvs[Self.relayTokenType] else { return false }
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// The lease id the header names, when it carries the relay's token
    /// and the id is one (isLeaseID); nil otherwise.
    public func admittedLease(relayToken token: String) -> String? {
        guard carriesRelayToken(token), let lease = leaseID, Self.isLeaseID(lease) else { return nil }
        return lease
    }

    // MARK: Reading

    /// The header at the start of `bytes`, and how many bytes it took.
    public static func parse(_ bytes: [UInt8]) throws(Problem) -> (header: ProxyProtocolHeader, length: Int) {
        guard bytes.count >= 16 else {
            if !bytes.isEmpty, !signature.starts(with: bytes.prefix(12)) { throw .notProxyProtocol }
            throw .truncated
        }
        guard Array(bytes[0..<12]) == signature else { throw .notProxyProtocol }
        let versionCommand = bytes[12]
        guard versionCommand >> 4 == 2 else { throw .unsupportedVersion(versionCommand >> 4) }
        guard let command = Command(rawValue: versionCommand & 0x0F) else { throw .unknownCommand(versionCommand & 0x0F) }
        let family = bytes[13]
        let length = Int(bytes[14]) << 8 | Int(bytes[15])
        guard bytes.count >= 16 + length else { throw .truncated }
        let body = Array(bytes[16..<(16 + length)])
        let addressLength = switch family >> 4 {
        case 1: 12   // IPv4: two addresses, two ports
        case 2: 36   // IPv6
        case 3: 216  // Unix: two 108-byte paths
        default: 0
        }
        guard body.count >= addressLength else { throw .truncated }
        var tlvs: [UInt8: [UInt8]] = [:]
        var index = addressLength
        while index < body.count {
            guard index + 3 <= body.count else { throw .badTLV }
            let type = body[index]
            let size = Int(body[index + 1]) << 8 | Int(body[index + 2])
            guard index + 3 + size <= body.count else { throw .badTLV }
            tlvs[type] = Array(body[(index + 3)..<(index + 3 + size)])
            index += 3 + size
        }
        let header = ProxyProtocolHeader(command: command, family: family, addresses: Array(body[0..<addressLength]), tlvs: tlvs)
        return (header, 16 + length)
    }

    /// Reads exactly one header from `descriptor`, and nothing after it, so
    /// what follows on the stream is the container's own.
    /// `within`: the seconds the whole header may take, however it's
    /// dribbled in (NCH's review of #414: each read's wait alone would let a
    /// byte a second hold a stream for minutes); nil, each read waits as
    /// the descriptor says.
    public static func read(from descriptor: Int32, within seconds: Double? = nil) throws(Problem) -> ProxyProtocolHeader {
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        let fixed = try readExactly(16, from: descriptor, by: deadline)
        guard Array(fixed[0..<12]) == signature else { throw .notProxyProtocol }
        let length = Int(fixed[14]) << 8 | Int(fixed[15])
        let rest = try readExactly(length, from: descriptor, by: deadline)
        return try parse(fixed + rest).header
    }

    private static func readExactly(_ count: Int, from descriptor: Int32, by deadline: Date?) throws(Problem) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw .truncated }
                agent_proxy_set_receive_timeout_ms(descriptor, Int32(min(left * 1000, 60_000).rounded(.up)))
            }
            let read = bytes.withUnsafeMutableBytes { buffer in Foundation.read(descriptor, buffer.baseAddress! + got, count - got) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw .truncated }
            got += read
        }
        return bytes
    }

    // MARK: Writing (the relay's side, and tests)

    /// The header as bytes: `family` 0x00 and no addresses unless given.
    public func encoded() -> [UInt8] {
        var body = addresses
        for (type, value) in tlvs.sorted(by: { $0.key < $1.key }) {
            body += [type, UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
        }
        return Self.signature + [0x20 | command.rawValue, family, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    public init(command: Command, family: UInt8 = 0, addresses: [UInt8] = [], tlvs: [UInt8: [UInt8]] = [:]) {
        self.command = command
        self.family = family
        self.addresses = addresses
        self.tlvs = tlvs
    }

    /// A relayed stream's header: the container's lease and the relay's token.
    public static func relayed(lease: String, relayToken: String) -> ProxyProtocolHeader {
        ProxyProtocolHeader(command: .proxy, tlvs: [leaseIDType: Array(lease.utf8), relayTokenType: Array(relayToken.utf8)])
    }
}
