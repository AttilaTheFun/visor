// Some secrets kept where only this app's own signed processes read them,
// the rest where they always were. On a Mac (visor#471's follow-up, NCH's
// review): the app key in the data-protection keychain under the app's own
// keychain access group, which another process of this user's (an agent's
// `security find-generic-password`) is told holds nothing, with no prompt
// to click through; everything else in the login keychain as before.
//
// A process with no protected store (a build signed ad hoc, or without the
// profile that grants its group) keeps every secret where it was. One with
// it moves each protected secret over the first time it's read: written
// there, read back, and only then deleted from where it was. A write that
// doesn't read back leaves the secret where it was, said in the log.

import Synchronization

/// Secrets by name: `names` in `protected` when there is one, every other
/// (and every one without it) in `legacy`.
public final class ProtectedSecrets: SecretStore {
    private let legacy: any SecretStore
    private let protected: (any SecretStore)?
    private let names: Set<String>
    private let unprotected: String
    private let log: @Sendable (String) -> Void
    /// The lines said already, so each is said once.
    private let said = Mutex<Set<String>>([])

    /// `unprotected`: why there's no protected store, for the log.
    public init(legacy: any SecretStore, protected: (any SecretStore)?, names: Set<String>, unprotected: String = "",
                log: @escaping @Sendable (String) -> Void) {
        self.legacy = legacy
        self.protected = protected
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
        // Not there yet: the legacy store's, moved over if it reads back.
        let old = legacy.lookup(key)
        guard case .found(let value) = old else { return old }
        if wrote(key, value, to: protected) {
            legacy.set(key, nil)
            say("\(key): moved to the protected store, and deleted from the legacy store")
        } else {
            say("\(key): stays in the legacy store (the protected store's write didn't read back)")
        }
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
        if wrote(key, value, to: protected) {
            // No copy left behind where any process of the user's reads it.
            legacy.set(key, nil)
            say("\(key): in the protected store")
        } else {
            // Nothing stale left to be read before the legacy store's.
            protected.set(key, nil)
            legacy.set(key, value)
            say("\(key): in the legacy store (the protected store's write didn't read back)")
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
