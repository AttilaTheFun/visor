// Compact JWS (RFC 7515) with HS256 (HMAC-SHA256, swift-crypto's): the
// agents' tokens (AgentTokens). Three base64url parts, header, payload and
// signature, joined by dots; the header names its key (`kid`). Only HS256
// is made or taken: a token whose header says another algorithm (`none`
// among them) is refused before its key is looked for.

import Crypto
import Foundation

package enum JWT {
    /// A token's header.
    package struct Header: Codable, Equatable, Sendable {
        package var alg: String
        package var typ: String
        package var kid: String
    }

    /// A token taken apart (not yet verified): its header, its payload's
    /// bytes, what was signed and the signature.
    package struct Parts: Sendable {
        package let header: Header
        package let payload: Data
        package let signed: Data
        package let signature: Data
    }

    /// The one algorithm made and taken.
    package static let algorithm = "HS256"

    /// `payload` signed with `key`, named `kid`.
    package static func sign<Payload: Encodable>(_ payload: Payload, key: Data, kid: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(Header(alg: algorithm, typ: "JWT", kid: kid))
        let body = try encoder.encode(payload)
        let signed = base64URL(header) + "." + base64URL(body)
        return signed + "." + base64URL(Data(mac(Data(signed.utf8), key: key)))
    }

    /// `token` taken apart, if it has a JWT's shape and an HS256 header.
    package static func parts(of token: String) -> Parts? {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let headerData = data(base64URL: pieces[0]), let payload = data(base64URL: pieces[1]),
              let signature = data(base64URL: pieces[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == algorithm, header.typ == "JWT", !header.kid.isEmpty else { return nil }
        return Parts(header: header, payload: payload, signed: Data((pieces[0] + "." + pieces[1]).utf8), signature: signature)
    }

    /// Whether `parts` were signed with `key`, compared in constant time.
    package static func verify(_ parts: Parts, key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(parts.signature, authenticating: parts.signed, using: SymmetricKey(data: key))
    }

    /// Whether `token` looks like a JWT (three dotted parts), whatever it
    /// says: one that doesn't is an older random token.
    package static func isShaped(_ token: String) -> Bool {
        token.split(separator: ".", omittingEmptySubsequences: false).count == 3
    }

    private static func mac(_ data: Data, key: Data) -> HMAC<SHA256>.MAC {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
    }

    /// Base64url, without padding.
    package static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url's bytes, with or without padding; nil for anything else.
    package static func data<Text: StringProtocol>(base64URL text: Text) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 { plain += "=" }
        return Data(base64Encoded: plain)
    }
}
