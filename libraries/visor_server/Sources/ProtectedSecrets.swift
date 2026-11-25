// Some secrets kept where only this app's own signed processes read them,
// the rest where they always were. On a Mac (visor#471's follow-up, NCH's
// review): the app key and the admin token itself in the data-protection
// keychain under the app's own keychain access group, which another
// process of this user's (an agent's `security find-generic-password`) is
// told holds nothing, with no prompt to click through; everything else in
// the login keychain as before.
//
// A process with no protected store (a build signed ad hoc, or without the
// profile that grants its group) keeps every secret where it was. One with
// it moves each protected secret over the first time it's read, from the
// legacy store or from anywhere else it may have been left (`elsewhere`:
// on a Mac, another access group the app reaches), so a secret kept once
// is never made again beside it.
//
// The order matters on a Mac (0.66: the app key was lost at every start of
// the server agent). A delete from the login keychain, asked without the
// data-protection keychain's flag, deletes the item of the same service
// and account from the data-protection keychain too: macOS runs it on
// both (`SecItemDelete_ios` beside the file keychain's). So the copy where
// a secret was is deleted first, and only then is it written where it goes
// and read back. Deleted after, it took the new copy with it, and the
// secret lived in the memory of the process that wrote it alone. A write
// that doesn't read back puts the secret back where it was, said in the
// log.
//
// Or the legacy store's copies are kept (`keepsLegacy`: the client's items
// on a Mac, 0.66's prep for the sandboxed release, NCH's review of #503).
// A build rolled back to (0.66.1, or the update watcher's own undo) reads
// the login keychain alone, so its copy stays there, whole: each item is
// copied to the protected store (written, read back), never moved, and
// nothing is ever deleted or updated in the legacy store, since a
// legacy-flavoured delete reaches the protected item (above) and an update
// may too. Reads ask the protected store first, then the legacy one, whose
// item is copied over. Writes go to the protected store alone, so the
// legacy copy goes stale from then on (it's for a rollback through the prep
// release; it stays until a person removes it in Keychain Access). A secret removed is removed from the
// protected store, and the legacy copy it had then is noted as forgotten
// (`forgottenName`, by its value's hash), so a read doesn't bring it back;
// a different value there later (written by a build rolled back to) is
// copied as any other.

import Crypto
import Foundation
import Synchronization

/// Secrets by name: `names` in `protected` when there is one, every other
/// (and every one without it) in `legacy`.
public final class ProtectedSecrets: SecretStore {
    private let legacy: any SecretStore
    private let protected: (any SecretStore)?
    /// Where else a protected secret may have been left, looked in (in
    /// order) when `protected` hasn't it: moved from there.
    private let elsewhere: [any SecretStore]
    private let protects: @Sendable (String) -> Bool
    private let unprotected: String
    /// The legacy store's copies kept: copied, never moved, and the legacy
    /// store never written to while there's a protected store.
    private let keepsLegacy: Bool
    private let log: @Sendable (String) -> Void
    /// The lines said already, so each is said once.
    private let said = Mutex<Set<String>>([])

    /// `unprotected`: why there's no protected store, for the log.
    public convenience init(legacy: any SecretStore, protected: (any SecretStore)?, elsewhere: [any SecretStore] = [], names: Set<String>,
                            unprotected: String = "", log: @escaping @Sendable (String) -> Void) {
        self.init(legacy: legacy, protected: protected, elsewhere: elsewhere, protecting: { names.contains($0) },
                  unprotected: unprotected, log: log)
    }

    /// The secrets `protecting` says, by name, in `protected`: every one
    /// of a service's, say (the client's on a Mac, 0.66: its computers'
    /// passwords, its SSH key and what it keeps with them).
    /// `keepsLegacy`: the legacy store's copies kept (above), the
    /// client's on a Mac.
    public init(legacy: any SecretStore, protected: (any SecretStore)?, elsewhere: [any SecretStore] = [],
                protecting: @escaping @Sendable (String) -> Bool, keepsLegacy: Bool = false, unprotected: String = "",
                log: @escaping @Sendable (String) -> Void) {
        self.legacy = legacy
        self.protected = protected
        self.elsewhere = elsewhere
        self.protects = protecting
        self.keepsLegacy = keepsLegacy
        self.unprotected = unprotected
        self.log = log
    }

    /// The protected store's item that notes the legacy copies of secrets
    /// removed since (`keepsLegacy`): a JSON object of each one's name and
    /// its value's hash. Never a secret's own name.
    public static let forgottenName = "visor.legacy-forgotten"

    /// Each of `keys` the legacy store holds (as its own list says) brought
    /// to the protected store now, as a read would bring it, rather than
    /// the first time it's read: moved, or copied with `keepsLegacy`. What
    /// a build that can still read the legacy store does for one that
    /// won't (0.66, before Visor.app is sandboxed: a sandboxed app can't
    /// read the login keychain's items). Nothing without a protected store.
    public func moveAll(_ keys: [String]) {
        guard protected != nil else { return }
        for key in keys where protects(key) && key != Self.forgottenName { _ = lookup(key) }
    }

    public func get(_ key: String) -> String? {
        guard case .found(let value) = lookup(key) else { return nil }
        return value
    }

    public func lookup(_ key: String) -> SecretLookup {
        guard protects(key) else { return legacy.lookup(key) }
        guard let protected else {
            say("\(key): in the legacy store (\(unprotected.isEmpty ? "no protected store" : unprotected))")
            return legacy.lookup(key)
        }
        let kept = protected.lookup(key)
        guard kept == .absent else {
            if case .found = kept { say("\(key): in the protected store") }
            return kept
        }
        // Not there yet: wherever else it was left, moved (or copied) over.
        for other in elsewhere {
            guard case .found(let value) = other.lookup(key) else { continue }
            bring(key, value, from: other, to: protected, what: "another access group")
            return .found(value)
        }
        let old = legacy.lookup(key)
        guard case .found(let value) = old else { return old }
        // A legacy copy of a secret removed since isn't brought back.
        if keepsLegacy, forgotten(in: protected)[key] == Self.hash(value) { return .absent }
        bring(key, value, from: legacy, to: protected, what: "the legacy store")
        return .found(value)
    }

    public func set(_ key: String, _ value: String?) {
        guard protects(key), let protected else {
            legacy.set(key, value)
            return
        }
        if keepsLegacy { return keep(key, value, in: protected) }
        guard let value, !value.isEmpty else {
            protected.set(key, nil)
            legacy.set(key, nil)
            return
        }
        // No copy left behind where any process of the user's reads it:
        // deleted before the write (above, why).
        legacy.set(key, nil)
        if wrote(key, value, to: protected) {
            say("\(key): in the protected store")
        } else {
            // Nothing stale left to be read before the legacy store's.
            protected.set(key, nil)
            legacy.set(key, value)
            say("\(key): in the legacy store (the protected store's write didn't read back)")
        }
    }

    /// The protected store's alone (`keepsLegacy`): the legacy store is
    /// read, never written. Removed: the legacy copy it has now noted as
    /// forgotten. Written: no longer forgotten.
    private func keep(_ key: String, _ value: String?, in protected: any SecretStore) {
        var forgotten = forgotten(in: protected)
        guard let value, !value.isEmpty else {
            protected.set(key, nil)
            say("\(key): removed from the protected store")
            if case .found(let old) = legacy.lookup(key) {
                forgotten[key] = Self.hash(old)
                note(forgotten, in: protected)
                say("\(key): the legacy store's copy kept, and forgotten")
            }
            return
        }
        if wrote(key, value, to: protected) {
            say("\(key): in the protected store (the legacy store's copy kept)")
            if forgotten.removeValue(forKey: key) != nil { note(forgotten, in: protected) }
        } else {
            protected.set(key, nil)
            say("\(key): not kept: the protected store's write didn't read back, and the legacy store isn't written to")
        }
    }

    /// The legacy copies of secrets removed since, by name: their values'
    /// hashes.
    private func forgotten(in protected: any SecretStore) -> [String: String] {
        guard case .found(let text) = protected.lookup(Self.forgottenName),
              let notes = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return [:] }
        return notes
    }

    private func note(_ forgotten: [String: String], in protected: any SecretStore) {
        guard !forgotten.isEmpty, let data = try? JSONEncoder().encode(forgotten) else {
            protected.set(Self.forgottenName, nil)
            return
        }
        protected.set(Self.forgottenName, String(decoding: data, as: UTF8.self))
    }

    /// A value's SHA-256, hex: what's noted of a forgotten copy, never the
    /// copy itself.
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `value` brought from `source` to `protected`: copied when the legacy
    /// copies are kept, else moved.
    private func bring(_ key: String, _ value: String, from source: any SecretStore, to protected: any SecretStore, what: String) {
        guard keepsLegacy else { return move(key, value, from: source, to: protected, what: what) }
        if wrote(key, value, to: protected) {
            say("\(key): copied to the protected store from \(what), which keeps its copy")
        } else {
            protected.set(key, nil)
            say("\(key): stays in \(what) alone (the protected store's write didn't read back)")
        }
    }

    /// `value` moved from `source` to `protected`: deleted there, then
    /// written here and read back; put back there when it doesn't read
    /// back.
    private func move(_ key: String, _ value: String, from source: any SecretStore, to protected: any SecretStore, what: String) {
        source.set(key, nil)
        if wrote(key, value, to: protected) {
            say("\(key): moved to the protected store from \(what)")
        } else {
            protected.set(key, nil)
            source.set(key, value)
            say("\(key): stays in \(what) (the protected store's write didn't read back)")
        }
    }

    /// `value` written to `store` and read back as written.
    private func wrote(_ key: String, _ value: String, to store: any SecretStore) -> Bool {
        store.set(key, value)
        return store.lookup(key) == .found(value)
    }

    private func say(_ line: String) {
        guard said.withLock({ $0.insert(line).inserted }) else { return }
        log(line)
    }
}
