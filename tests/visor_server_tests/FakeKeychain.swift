// A keychain standing in for the server's secrets in the tests of where
// they're kept (ProtectedSecretsTests, AppKeyKeeperTests): a Mac's login
// keychain, whose delete reaches the data-protection keychain, as one
// reaching another.

import Synchronization
@testable import VisorServer

/// A keychain standing in: what it keeps, a write it can be told to drop
/// (a keychain refusing it), a read it can be told to fail, and its calls.
/// `reaching`: another whose item of the same name a delete here deletes
/// too, as a Mac's delete from the login keychain (asked without the
/// data-protection keychain's flag) deletes the data-protection keychain's.
final class FakeKeychain: SecretStore {
    private let values = Mutex<[String: String]>([:])
    private let calls = Mutex<[String]>([])
    let dropsWrites: Bool
    let unreadable: Bool
    let reaching: FakeKeychain?
    let journal: Journal?
    let label: String

    init(dropsWrites: Bool = false, unreadable: Bool = false, holding: [String: String] = [:], reaching: FakeKeychain? = nil,
         journal: Journal? = nil, label: String = "") {
        self.dropsWrites = dropsWrites
        self.unreadable = unreadable
        self.reaching = reaching
        self.journal = journal
        self.label = label
        values.withLock { $0 = holding }
    }

    var kept: [String: String] { values.withLock { $0 } }
    var log: [String] { calls.withLock { $0 } }

    func get(_ key: String) -> String? {
        guard case .found(let value) = lookup(key) else { return nil }
        return value
    }

    func lookup(_ key: String) -> SecretLookup {
        calls.withLock { $0.append("lookup \(key)") }
        if unreadable { return .unreadable("keychain error -25308") }
        return values.withLock { $0[key] }.map(SecretLookup.found) ?? .absent
    }

    func set(_ key: String, _ value: String?) {
        let call = value == nil ? "delete \(key)" : "set \(key)"
        calls.withLock { $0.append(call) }
        journal?.add("\(label) \(call)")
        if value == nil { reaching?.drop(key) }
        if dropsWrites && value != nil { return }
        values.withLock { $0[key] = value.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Deleted by another's delete (`reaching`).
    func drop(_ key: String) { values.withLock { $0[key] = nil } }
}
