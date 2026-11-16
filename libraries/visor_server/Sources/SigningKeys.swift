// The keys the agents' tokens are signed with (AgentTokens): random 32-byte
// keys, each named by a `kid`, one of them current, kept with the server's
// secrets (the keychain on a Mac, the secrets file elsewhere) as one JSON
// object. Rotating makes a new current key and keeps the one before until
// the longest-lived token it signed has ended (a session's, a day), then
// drops it; an emergency rotation drops every other key at once, and with
// them every token they signed.

import Crypto
import Foundation

@MainActor
package final class SigningKeys {
    /// A key as kept: its bytes (base64), when it was made, and when it
    /// stopped being current (nil while it is).
    package struct Kept: Codable, Equatable, Sendable {
        package var key: String
        package var created: Double
        package var retired: Double?
    }

    /// The set as kept.
    package struct KeySet: Codable, Equatable, Sendable {
        package var current: String
        package var keys: [String: Kept]
    }

    /// Where they are kept among the server's secrets.
    package static let secretKey = "signingKeys"

    /// How long a key that stopped being current is kept: as long as the
    /// longest-lived token it signed lasts.
    package static let previousKeyLife: TimeInterval = 24 * 3600

    private let secrets: any SecretStore
    private var set: KeySet

    /// The keys kept, or a first key made and kept.
    package init(secrets: any SecretStore, now: Date = Date()) {
        self.secrets = secrets
        if let text = secrets.get(Self.secretKey), let decoded = try? JSONDecoder().decode(KeySet.self, from: Data(text.utf8)),
           decoded.keys[decoded.current] != nil {
            set = decoded
            if prune(now: now) { keep() }
        } else {
            let kid = Self.newKID()
            set = KeySet(current: kid, keys: [kid: Kept(key: Self.newKey(), created: now.timeIntervalSince1970, retired: nil)])
            keep()
        }
    }

    /// The current key's name.
    package var currentKID: String { set.current }

    /// The current key, to sign with.
    package var current: (kid: String, key: Data) {
        (set.current, Data(base64Encoded: set.keys[set.current]?.key ?? "") ?? Data())
    }

    /// Every key held, by name: the current one and those still kept.
    package var kids: [String] { set.keys.keys.sorted() }

    /// The key named `kid`, while it is held (current, or retired less than
    /// `previousKeyLife` ago).
    package func key(_ kid: String, now: Date = Date()) -> Data? {
        guard let kept = set.keys[kid] else { return nil }
        if let retired = kept.retired, now.timeIntervalSince1970 - retired >= Self.previousKeyLife { return nil }
        return Data(base64Encoded: kept.key)
    }

    /// A new current key. The one before is kept until the tokens it
    /// signed have ended, unless `dropPrevious` (an emergency): then every
    /// other key goes now, and every token signed with one is refused.
    /// The new key's name.
    @discardableResult
    package func rotate(dropPrevious: Bool, now: Date = Date()) -> String {
        let kid = Self.newKID()
        if dropPrevious {
            set.keys = [:]
        } else if var before = set.keys[set.current] {
            before.retired = now.timeIntervalSince1970
            set.keys[set.current] = before
        }
        set.keys[kid] = Kept(key: Self.newKey(), created: now.timeIntervalSince1970, retired: nil)
        set.current = kid
        _ = prune(now: now)
        keep()
        return kid
    }

    /// Drops the keys retired longer than `previousKeyLife` ago: whether
    /// any went.
    @discardableResult
    package func prune(now: Date = Date()) -> Bool {
        let before = set.keys.count
        set.keys = set.keys.filter { kid, kept in
            kid == set.current || kept.retired.map { now.timeIntervalSince1970 - $0 < Self.previousKeyLife } ?? true
        }
        return set.keys.count != before
    }

    private func keep() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(set) else { return }
        secrets.set(Self.secretKey, String(decoding: data, as: UTF8.self))
    }

    /// 32 random bytes, as base64.
    private static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    /// A key's name: 8 random bytes, as hex.
    private static func newKID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
