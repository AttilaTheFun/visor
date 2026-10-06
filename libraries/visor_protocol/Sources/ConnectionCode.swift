// A computer's connection code: what the menu bar app shows (as a string
// to copy and a QR code to scan) and what a client takes to add the
// computer in one step — its name, its address on the network, and its
// password. URL-safe base64 of a small JSON object, so it survives being
// pasted anywhere and put in a link (`visor://connect?code=…`).
//
// By hand, without Foundation: the same code runs in the web client.

public struct ConnectionCode: Equatable, Sendable {
    public var name: String
    /// Where clients reach it: a Tailscale name (HTTPS on 443 at the
    /// root), or the URL a proxy or a tunnel gives (`ServerAddress`).
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
