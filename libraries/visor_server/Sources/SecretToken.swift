// The bearer tokens the server makes for its agents (and the dispatcher
// for its runners' agents): minted from 32 random bytes, and compared in a
// time that doesn't say how much of a guess matched. Every secret a client
// shows is compared here: the password, `hello`'s tokens, the app key, a
// front's token, the admin token's hash and the agents' and runners' own.

import Foundation

public enum SecretToken {
    /// A new token: 32 random bytes from the system's generator, as 64
    /// hexadecimal digits.
    public static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// Whether `given` is `kept`, every byte looked at whichever differs
    /// first. Neither may be empty: no token matches an empty one.
    public static func same(_ given: String?, _ kept: String?) -> Bool {
        guard let given, let kept else { return false }
        return same(Array(given.utf8), Array(kept.utf8))
    }

    /// Whether the bytes `given` are `kept`'s, every byte of `kept` looked
    /// at whichever differs first: the time says how long `kept` is, never
    /// how much of `given` matched. Neither may be empty.
    public static func same(_ given: [UInt8], _ kept: [UInt8]) -> Bool {
        guard !given.isEmpty, !kept.isEmpty else { return false }
        var difference = UInt8(given.count == kept.count ? 0 : 1)
        for index in kept.indices { difference |= kept[index] ^ (index < given.count ? given[index] : 0) }
        return difference == 0
    }

    /// Whether `given` is one of `kept`, every one of them compared whole
    /// (`same`), whichever it is and whether or not it is there.
    public static func any(_ kept: some Sequence<String>, is given: String?) -> Bool {
        guard let given else { return false }
        let shown = Array(given.utf8)
        var found = false
        for token in kept where same(shown, Array(token.utf8)) { found = true }
        return found
    }
}
