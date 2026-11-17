// The keys the agents' tokens are signed with (AgentTokens): random 32-byte
// keys, each named by a `kid`, one of them current, kept with the server's
// secrets (the keychain on a Mac, the secrets file elsewhere) as one JSON
// object. Rotating makes a new current key and keeps the one before until
// the longest-lived token it signed has ended (a session's, a day); after
// that, for AgentTokens.expiredTokenGrace more, it only verifies, and only
// what may be taken past its end (a runner's Renew and Release: AgentTokens'
// `withinGrace`), so an ordinary rotation never ends a runner's long job
// sooner than its token's own end would. It is never signed with again
// once it isn't current. An emergency rotation drops every other key at
// once, and with them every token they signed, grace or not.
//
// The keys are made only when the secrets say there are none. Kept keys
// that can't be read (the keychain refused, the file is unreadable) or
// can't be decoded are never written over: nothing is minted (each try
// says so in the log) until they read again, which is tried again at most
// every `retryInterval`, or an emergency rotation replaces them.

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

    /// How long a key that stopped being current verifies every token it
    /// signed: as long as the longest-lived of them lasts.
    package static let previousKeyLife: TimeInterval = 24 * 3600

    /// How long after a failed read the kept keys are read again.
    static let retryInterval: TimeInterval = 30

    private let secrets: any SecretStore
    /// The keys, once read or made; nil while those kept can't be read.
    private var keySet: KeySet?
    /// Why the kept keys can't be used, while they can't.
    package private(set) var problem: String?
    private var lastRead = Date.distantPast

    /// The keys kept, or a first key made and kept when there are none.
    package init(secrets: any SecretStore, now: Date = Date()) {
        self.secrets = secrets
        load(now: now)
    }

    /// The current key's name ("" while the keys can't be read).
    package var currentKID: String { held()?.current ?? "" }

    /// The current key, to sign with; nil while the keys can't be read.
    package var current: (kid: String, key: Data)? {
        guard let keySet = held(), let kept = keySet.keys[keySet.current], let key = Data(base64Encoded: kept.key) else { return nil }
        return (keySet.current, key)
    }

    /// The keys that verify every token they signed, by name: the current
    /// one and those retired less than `previousKeyLife` ago.
    package var kids: [String] { kids(now: Date()) }

    package func kids(now: Date) -> [String] {
        let at = now.timeIntervalSince1970
        return (held(now: now)?.keys ?? [:]).filter { $0.value.retired.map { at - $0 < Self.previousKeyLife } ?? true }.keys.sorted()
    }

    /// The keys past their life that still verify, for `expiredTokenGrace`,
    /// what may be taken past its end (until `prune` drops them).
    package var graceKIDs: [String] { graceKIDs(now: Date()) }

    package func graceKIDs(now: Date) -> [String] {
        let at = now.timeIntervalSince1970
        let life = Self.previousKeyLife + AgentTokens.expiredTokenGrace
        return (held(now: now)?.keys ?? [:]).filter { _, kept in
            kept.retired.map { at - $0 >= Self.previousKeyLife && at - $0 < life } ?? false
        }.keys.sorted()
    }

    /// The key named `kid`, while it is held: current, or retired less than
    /// `previousKeyLife` ago; or, `withinGrace`, less than `previousKeyLife`
    /// and `AgentTokens.expiredTokenGrace` ago (verify-only: such a key is
    /// never current, and never signs).
    package func key(_ kid: String, now: Date = Date(), withinGrace: Bool = false) -> Data? {
        guard let kept = held(now: now)?.keys[kid] else { return nil }
        if let retired = kept.retired {
            let life = Self.previousKeyLife + (withinGrace ? AgentTokens.expiredTokenGrace : 0)
            if now.timeIntervalSince1970 - retired >= life { return nil }
        }
        return Data(base64Encoded: kept.key)
    }

    /// A new current key. The one before is kept until the tokens it
    /// signed have ended (and their grace), unless `dropPrevious` (an
    /// emergency): then every other key goes now, and every token signed
    /// with one is refused. The new key's name; nil when the kept keys
    /// can't be read and this isn't an emergency (which replaces them).
    @discardableResult
    package func rotate(dropPrevious: Bool, now: Date = Date()) -> String? {
        let kid = Self.newKID()
        var next: KeySet
        if dropPrevious {
            next = KeySet(current: kid, keys: [:])
        } else if var set = held(now: now) {
            if var before = set.keys[set.current] {
                before.retired = now.timeIntervalSince1970
                set.keys[set.current] = before
            }
            next = set
        } else {
            VisorServer.log("signing keys: not rotated: \(problem ?? "the kept keys can't be read")")
            return nil
        }
        next.keys[kid] = Kept(key: Self.newKey(), created: now.timeIntervalSince1970, retired: nil)
        next.current = kid
        keySet = next
        problem = nil
        _ = prune(now: now)
        keep()
        return kid
    }

    /// Drops the keys retired longer than `previousKeyLife` and
    /// `expiredTokenGrace` ago: whether any went.
    @discardableResult
    package func prune(now: Date = Date()) -> Bool {
        guard var set = keySet else { return false }
        let before = set.keys.count
        let life = Self.previousKeyLife + AgentTokens.expiredTokenGrace
        let current = set.current
        set.keys = set.keys.filter { kid, kept in
            kid == current || kept.retired.map { now.timeIntervalSince1970 - $0 < life } ?? true
        }
        keySet = set
        return set.keys.count != before
    }

    /// The keys, read again first while they couldn't be (at most every
    /// `retryInterval`).
    private func held(now: Date = Date()) -> KeySet? {
        if keySet == nil, now.timeIntervalSince(lastRead) >= Self.retryInterval { load(now: now) }
        return keySet
    }

    /// The kept keys read: made only when the secrets say there are none;
    /// left alone, and said, when they can't be read or decoded.
    private func load(now: Date) {
        lastRead = now
        switch secrets.lookup(Self.secretKey) {
        case .absent:
            let kid = Self.newKID()
            keySet = KeySet(current: kid, keys: [kid: Kept(key: Self.newKey(), created: now.timeIntervalSince1970, retired: nil)])
            problem = nil
            keep()
        case .found(let text):
            guard let decoded = try? JSONDecoder().decode(KeySet.self, from: Data(text.utf8)), decoded.keys[decoded.current] != nil else {
                fail("the kept signing keys can't be decoded")
                return
            }
            keySet = decoded
            problem = nil
            if prune(now: now) { keep() }
        case .unreadable(let why):
            fail("the kept signing keys can't be read (\(why))")
        }
    }

    private func fail(_ why: String) {
        keySet = nil
        problem = why
        VisorServer.log("signing keys: \(why): no agent's token is minted or verified until they read again, or an emergency "
            + "rotation replaces them; they aren't written over")
    }

    private func keep() {
        guard let keySet else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(keySet) else { return }
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
