import Foundation

/// A JSON value as GitHubGate reads a body: strictly, so that the gate and
/// GitHub can't read one body two ways. A key twice in one object
/// (`{"draft":true,"draft":false}`), anything after the value, or a document
/// deeper than 64 levels is no JSON here (docs/github-gate-rules.md, §3).
indirect enum GateJSON: Equatable, Sendable {
    case object([String: GateJSON])
    case array([GateJSON])
    case string(String)
    /// Its digits as written.
    case number(String)
    case bool(Bool)
    case null

    /// The value `data` is, or nil.
    static func parse(_ data: Data) -> GateJSON? {
        var reader = Reader(bytes: Array(data))
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipSpace()
        return reader.at == reader.bytes.count ? value : nil
    }

    var object: [String: GateJSON]? { if case .object(let o) = self { o } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [GateJSON]? { if case .array(let a) = self { a } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func value(depth: Int) -> GateJSON? {
            guard depth < 64 else { return nil }
            skipSpace()
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(GateJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ value: GateJSON) -> GateJSON? {
            let letters = Array(word.utf8)
            guard at + letters.count <= bytes.count, Array(bytes[at..<at + letters.count]) == letters else { return nil }
            at += letters.count
            return value
        }

        mutating func object(depth: Int) -> GateJSON? {
            at += 1
            var members: [String: GateJSON] = [:]
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
                at += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                guard let member = value(depth: depth + 1), members[key] == nil else { return nil }
                members[key] = member
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(members) }
                return nil
            }
        }

        mutating func array(depth: Int) -> GateJSON? {
            at += 1
            var items: [GateJSON] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
                at += 1
                return .array(items)
            }
            while true {
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            at += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() -> Bool {
                guard !raw.isEmpty else { return true }
                guard let text = String(validating: raw, as: UTF8.self) else { return false }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
                return true
            }
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return flush() ? String(scalars) : nil
                case UInt8(ascii: "\\"):
                    guard flush(), at < bytes.count else { return nil }
                    let escaped = bytes[at]
                    at += 1
                    switch escaped {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code) {
                            guard at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else { return nil }
                            at += 2
                            guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { return nil }
                        scalars.append(scalar)
                    default:
                        return nil
                    }
                default:
                    guard byte >= 0x20 else { return nil }
                    raw.append(byte)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard at + 4 <= bytes.count, let text = String(bytes: bytes[at..<at + 4], encoding: .ascii),
                  let code = UInt32(text, radix: 16) else { return nil }
            at += 4
            return code
        }

        mutating func number() -> GateJSON? {
            let start = at
            while at < bytes.count, "+-.eE0123456789".utf8.contains(bytes[at]) { at += 1 }
            guard at > start, let text = String(bytes: bytes[start..<at], encoding: .ascii), Double(text) != nil else { return nil }
            return .number(text)
        }
    }
}
