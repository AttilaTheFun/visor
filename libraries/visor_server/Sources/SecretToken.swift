// The bearer tokens the server makes for its agents (and the dispatcher
// for its runners' agents): minted from 32 random bytes, and compared in a
// time that doesn't say how much of a guess matched.

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
        guard let given, let kept, !given.isEmpty, !kept.isEmpty else { return false }
        let x = Array(given.utf8), y = Array(kept.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in y.indices { difference |= y[index] ^ (index < x.count ? x[index] : 0) }
        return difference == 0
    }
}
