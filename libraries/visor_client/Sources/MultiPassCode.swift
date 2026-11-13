import VisorProtocol

/// A MultiPass's pairing code (MultiPass's docs/front-door.md):
/// `multipass1:` then, in base64url, JSON of the paths MultiPass is
/// reached at, its certificate's fingerprint, and a secret good once for
/// ten minutes. Pure Swift: Visor on the web has none of Foundation's
/// base64.
public struct MultiPassCode: Equatable, Sendable {
    public static let prefix = "multipass1:"

    public var paths: [String]
    public var fingerprint: String
    public var secret: String

    /// Nil for text that isn't one.
    public init?(_ text: String) {
        let trimmed = String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
        guard trimmed.hasPrefix(Self.prefix), let bytes = Self.base64URL(String(trimmed.dropFirst(Self.prefix.count))),
              let json = parseJSON(String(decoding: bytes, as: UTF8.self)),
              let paths = json["paths"].array?.compactMap(\.string), !paths.isEmpty,
              let secret = json["secret"].string, !secret.isEmpty else { return nil }
        self.paths = paths
        fingerprint = json["fingerprint"].string ?? ""
        self.secret = secret
    }

    /// Whether text looks like one, for a field that takes either it or a
    /// computer's own code.
    public static func isOne(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix(prefix)
    }

    /// base64url (or base64), with or without its padding.
    static func base64URL(_ text: String) -> [UInt8]? {
        var values: [UInt8] = []
        for scalar in text.unicodeScalars {
            switch scalar {
            case "A"..."Z": values.append(UInt8(scalar.value - 65))
            case "a"..."z": values.append(UInt8(scalar.value - 97 + 26))
            case "0"..."9": values.append(UInt8(scalar.value - 48 + 52))
            case "-", "+": values.append(62)
            case "_", "/": values.append(63)
            case "=": continue
            default: return nil
            }
        }
        guard values.count % 4 != 1 else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < values.count {
            let chunk = Array(values[index..<min(index + 4, values.count)])
            let a = chunk[0], b = chunk.count > 1 ? chunk[1] : 0
            bytes.append(a << 2 | b >> 4)
            if chunk.count > 2 { bytes.append((b & 0x0F) << 4 | chunk[2] >> 2) }
            if chunk.count > 3 { bytes.append((chunk[2] & 0x03) << 6 | chunk[3]) }
            index += 4
        }
        return bytes
    }
}
