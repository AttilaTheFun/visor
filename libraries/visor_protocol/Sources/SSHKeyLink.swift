/// A device's SSH public key as a `visor://authorize?key=…` link, for a QR
/// code: scanned by a device that already holds the computers, it has
/// them authorize the key, and the new device comes in over SSH with
/// nothing else — no HTTP pass, no password.
public struct SSHKeyLink: Equatable, Sendable {
    /// The key line (`ssh-ed25519 AAAA… comment`).
    public var key: String

    public init(key: String) { self.key = key }

    /// The link a QR code carries.
    public var link: String { "\(ConnectionCode.scheme)://authorize?key=\(Base64URL.encode(Array(key.utf8)))" }

    /// A link, or one with whitespace around it; nil for anything else.
    public init?(parsing text: String) {
        var value = Substring(text)
        while let first = value.first, first.isWhitespace || first.isNewline { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace || last.isNewline { value = value.dropLast() }
        guard value.lowercased().hasPrefix("\(ConnectionCode.scheme)://authorize?"), let range = value.range(of: "key=") else { return nil }
        value = value[range.upperBound...]
        if let end = value.firstIndex(of: "&") { value = value[..<end] }
        guard !value.isEmpty, let bytes = Base64URL.decode(String(value)) else { return nil }
        let key = String(decoding: bytes, as: UTF8.self)
        guard key.hasPrefix("ssh-") || key.hasPrefix("ecdsa-") || key.hasPrefix("sk-") else { return nil }
        self.init(key: key)
    }
}
