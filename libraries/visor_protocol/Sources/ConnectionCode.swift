// A computer's connection code: what the menu bar app shows (as a string
// to copy and a QR code to scan) and what a client takes to add the
// computer in one step — its name, its address on the network, and its
// password. URL-safe base64 of a small JSON object, so it survives being
// pasted anywhere and put in a link (`visor://connect?code=…`).
//
// By hand, without Foundation: the same code runs in the web client.

public struct ConnectionCode: Equatable, Sendable {
    public var name: String
    /// The Tailscale name clients reach it at (always HTTPS on 443).
    public var host: String
    public var password: String

    public init(name: String, host: String, password: String) {
        self.name = name
        self.host = host
        self.password = password
    }

    public static let scheme = "visor"

    /// The code itself: base64url, no padding.
    public var encoded: String {
        let json = JSONValue.object(["v": .number(1), "name": .string(name), "host": .string(host), "password": .string(password)])
        return Base64URL.encode(Array(json.encoded().utf8))
    }

    /// The link a QR code carries; opening it opens Visor with the code.
    public var link: String { "\(Self.scheme)://connect?code=\(encoded)" }

    /// A code, a `visor://connect?code=` link, or either with whitespace
    /// around it; nil for anything else.
    public init?(parsing text: String) {
        var value = Substring(text)
        while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace || last.isNewline { value = value.dropLast() }
        if let range = value.range(of: "code=") {
            value = value[range.upperBound...]
            if let end = value.firstIndex(of: "&") { value = value[..<end] }
        }
        guard !value.isEmpty, let bytes = Base64URL.decode(String(value)),
              let json = parseJSON(String(decoding: bytes, as: UTF8.self)),
              let host = json["host"].string, !host.isEmpty else { return nil }
        self.init(name: json["name"].string ?? host, host: host, password: json["password"].string ?? "")
    }
}

/// Base64 with the URL alphabet (`-` and `_`), written without padding
/// and read with or without it, in either alphabet.
enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i], b1 = i + 1 < bytes.count ? bytes[i + 1] : 0, b2 = i + 2 < bytes.count ? bytes[i + 2] : 0
            out.append(alphabet[Int(b0 >> 2)])
            out.append(alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
            if i + 1 < bytes.count { out.append(alphabet[Int((b1 & 0x0F) << 2 | b2 >> 6)]) }
            if i + 2 < bytes.count { out.append(alphabet[Int(b2 & 0x3F)]) }
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var values: [UInt8] = []
        for c in text.utf8 {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): values.append(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): values.append(c - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): values.append(c - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "-"), UInt8(ascii: "+"): values.append(62)
            case UInt8(ascii: "_"), UInt8(ascii: "/"): values.append(63)
            case UInt8(ascii: "="): continue
            default: return nil
            }
        }
        guard values.count % 4 != 1 else { return nil }
        var out: [UInt8] = []
        var i = 0
        while i < values.count {
            let v0 = values[i], v1 = i + 1 < values.count ? values[i + 1] : 0
            let v2 = i + 2 < values.count ? values[i + 2] : 0, v3 = i + 3 < values.count ? values[i + 3] : 0
            out.append(v0 << 2 | v1 >> 4)
            if i + 2 < values.count { out.append((v1 & 0x0F) << 4 | v2 >> 2) }
            if i + 3 < values.count { out.append((v2 & 0x03) << 6 | v3) }
            i += 4
        }
        return out
    }
}
