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

import Synchronization

/// Secrets by name: `names` in `protected` when there is one, every other
/// (and every one without it) in `legacy`.
public final class ProtectedSecrets: SecretStore {
    private let legacy: any SecretStore
    private let protected: (any SecretStore)?
    /// Where else a protected secret may have been left, looked in (in
    /// order) when `protected` hasn't it: moved from there.
    private let elsewhere: [any SecretStore]
    private let names: Set<String>
    private let unprotected: String
    private let log: @Sendable (String) -> Void
    /// The lines said already, so each is said once.
    private let said = Mutex<Set<String>>([])

    /// `unprotected`: why there's no protected store, for the log.
    public init(legacy: any SecretStore, protected: (any SecretStore)?, elsewhere: [any SecretStore] = [], names: Set<String>,
                unprotected: String = "", log: @escaping @Sendable (String) -> Void) {
        self.legacy = legacy
        self.protected = protected
        self.elsewhere = elsewhere
        self.names = names
        self.unprotected = unprotected
        self.log = log
    }

    public func get(_ key: String) -> String? {
        guard case .found(let value) = lookup(key) else { return nil }
        return value
    }

    public func lookup(_ key: String) -> SecretLookup {
        guard names.contains(key) else { return legacy.lookup(key) }
        guard let protected else {
            say("\(key): in the legacy store (\(unprotected.isEmpty ? "no protected store" : unprotected))")
            return legacy.lookup(key)
        }
        let kept = protected.lookup(key)
        guard kept == .absent else {
            if case .found = kept { say("\(key): in the protected store") }
            return kept
        }
        // Not there yet: wherever else it was left, moved over.
        for other in elsewhere {
            guard case .found(let value) = other.lookup(key) else { continue }
            move(key, value, from: other, to: protected, what: "another access group")
            return .found(value)
        }
        let old = legacy.lookup(key)
        guard case .found(let value) = old else { return old }
        move(key, value, from: legacy, to: protected, what: "the legacy store")
        return .found(value)
    }

    public func set(_ key: String, _ value: String?) {
        guard names.contains(key), let protected else {
            legacy.set(key, value)
            return
        }
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
