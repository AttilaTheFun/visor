// A DNS message, read only as far as forwarding needs: its id, whether it
// is a response, whether it was truncated, its answer's code, and the name
// its first question asks about. Everything else passes through as bytes.

import Foundation

/// A DNS message (RFC 1035 §4.1) as the agent proxy's resolver forwards it.
public struct DNSMessage: Sendable, Equatable {
    /// An answer's code (RCODE), the ones the resolver acts on.
    public enum Code: UInt8, Sendable {
        case noError = 0
        case formatError = 1
        case serverFailure = 2
        case nameError = 3
        case notImplemented = 4
        case refused = 5
    }

    /// The message as it came, or as it goes.
    public private(set) var bytes: [UInt8]

    /// The first question's name, lowercased, without the root's dot
    /// ("archive.ubuntu.com"); "" for the root.
    public let name: String

    /// Nil unless it holds a whole header and a first question.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        guard questions >= 1, let (name, end) = Self.readName(bytes, at: 12), end + 4 <= bytes.count else { return nil }
        self.bytes = bytes
        self.name = name
    }

    public var id: UInt16 { UInt16(bytes[0]) << 8 | UInt16(bytes[1]) }

    /// The first question's type (QTYPE): 1 for A, 28 for AAAA, and so on.
    public var type: UInt16 {
        guard let (_, end) = Self.readName(bytes, at: 12) else { return 0 }
        return UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1])
    }
    public var isResponse: Bool { bytes[2] & 0x80 != 0 }
    /// TC: the answer didn't fit in a datagram; ask again over TCP.
    public var isTruncated: Bool { bytes[2] & 0x02 != 0 }
    /// The answer's code; nil for one this resolver has no name for.
    public var code: Code? { Code(rawValue: bytes[3] & 0x0F) }

    /// The same message under another id.
    public func with(id: UInt16) -> DNSMessage {
        var copy = self
        copy.bytes[0] = UInt8(id >> 8)
        copy.bytes[1] = UInt8(id & 0xFF)
        return copy
    }

    /// The answer this resolver gives a query it can't answer otherwise:
    /// its header and first question, marked a response with `code`, and
    /// nothing else.
    public func answer(_ code: Code) -> DNSMessage {
        let (_, end) = Self.readName(bytes, at: 12) ?? ("", 12)
        var out = Array(bytes[0..<min(end + 4, bytes.count)])
        // QR set, the opcode and RD kept; RA set; the code given.
        out[2] = (out[2] & 0x79) | 0x80
        out[3] = 0x80 | code.rawValue
        // One question, no answers, authorities or additions.
        out[4] = 0; out[5] = 1
        for index in 6..<12 { out[index] = 0 }
        return DNSMessage(out) ?? self
    }

    /// The answer to an A query: its first question, and `address` (IPv4,
    /// four bytes) for that name, to be kept `ttl` seconds.
    public func answer(ipv4 address: [UInt8], ttl: UInt32) -> DNSMessage {
        var out = answer(.noError).bytes
        // One answer, its name the question's (a pointer to offset 12).
        out[7] = 1
        out += [0xC0, 0x0C, 0, 1, 0, 1]
        out += [UInt8(ttl >> 24), UInt8(ttl >> 16 & 0xFF), UInt8(ttl >> 8 & 0xFF), UInt8(ttl & 0xFF)]
        out += [0, 4] + address.prefix(4)
        return DNSMessage(out) ?? self
    }

    /// A query for `name` (type A unless given), for tests and probes.
    public static func query(id: UInt16, name: String, type: UInt16 = 1) -> DNSMessage? {
        var out: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            guard (1...63).contains(utf8.count) else { return nil }
            out.append(UInt8(utf8.count))
            out += utf8
        }
        out.append(0)
        out += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return DNSMessage(out)
    }

    /// The name at `offset` and the offset just past it. A question's name
    /// is never compressed in practice; a pointer is followed once, for
    /// safety, and ends the name.
    static func readName(_ bytes: [UInt8], at offset: Int) -> (String, Int)? {
        var labels: [String] = []
        var index = offset
        var length = 0
        while index < bytes.count {
            let size = Int(bytes[index])
            if size == 0 { return (labels.joined(separator: ".").lowercased(), index + 1) }
            if size & 0xC0 == 0xC0 {
                guard index + 1 < bytes.count else { return nil }
                let target = (size & 0x3F) << 8 | Int(bytes[index + 1])
                guard target < offset, let (rest, _) = readName(bytes, at: target) else { return nil }
                if !rest.isEmpty { labels.append(rest) }
                return (labels.joined(separator: ".").lowercased(), index + 2)
            }
            guard size <= 63, index + 1 + size <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(index + 1)...(index + size)], as: UTF8.self))
            length += size + 1
            guard length <= 255 else { return nil }
            index += 1 + size
        }
        return nil
    }
}
