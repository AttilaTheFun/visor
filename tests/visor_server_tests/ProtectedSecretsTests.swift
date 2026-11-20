// Which store a secret is kept in, and the move between them (visor#471's
// follow-up): Visor.app's app key in the protected store (the Mac's
// data-protection keychain under its own access group) when the build has
// one, else in the legacy store (the login keychain), as the log says;
// moved over the first time it's read, deleted from the legacy store only
// once the protected one reads it back. Fake keychains stand in for both.

import Synchronization
@testable import VisorServer
import Testing

/// A keychain standing in: what it keeps, a write it can be told to drop
/// (a keychain refusing it), a read it can be told to fail, and its calls.
private final class FakeKeychain: SecretStore {
    private let values = Mutex<[String: String]>([:])
    private let calls = Mutex<[String]>([])
    let dropsWrites: Bool
    let unreadable: Bool

    init(dropsWrites: Bool = false, unreadable: Bool = false, holding: [String: String] = [:]) {
        self.dropsWrites = dropsWrites
        self.unreadable = unreadable
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
        calls.withLock { $0.append(value == nil ? "delete \(key)" : "set \(key)") }
        if dropsWrites && value != nil { return }
        values.withLock { $0[key] = value.flatMap { $0.isEmpty ? nil : $0 } }
    }
}

/// The lines a store logs.
private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

extension ServerTests {
@Suite final class ProtectedSecretsTests {
    private let lines = Lines()

    private func store(legacy: FakeKeychain, protected: FakeKeychain?, unprotected: String = "") -> ProtectedSecrets {
        let lines = lines
        return ProtectedSecrets(legacy: legacy, protected: protected, names: ["app-key"], unprotected: unprotected,
                                log: { lines.add($0) })
    }

    // MARK: Which store

    @Test func withNoProtectedStoreTheAppKeyIsTheLegacyStoresAndTheLogSaysWhy() {
        let legacy = FakeKeychain()
        let secrets = store(legacy: legacy, protected: nil, unprotected: "signed ad hoc")
        secrets.set("app-key", "k1")
        #expect(legacy.kept["app-key"] == "k1")
        #expect(secrets.get("app-key") == "k1")
        #expect(secrets.get("app-key") == "k1")
        #expect(lines.all == ["app-key: in the legacy store (signed ad hoc)"])
    }

    @Test func withAProtectedStoreTheAppKeyIsWrittenThereAndNotToTheLegacyStore() {
        let legacy = FakeKeychain()
        let protected = FakeKeychain()
        let secrets = store(legacy: legacy, protected: protected)
        secrets.set("app-key", "k1")
        #expect(protected.kept["app-key"] == "k1")
        #expect(legacy.kept["app-key"] == nil)
        #expect(secrets.get("app-key") == "k1")
        #expect(lines.all == ["app-key: in the protected store"])
    }

    @Test func otherSecretsStayInTheLegacyStore() {
        let legacy = FakeKeychain(holding: ["password": "pw"])
        let protected = FakeKeychain()
        let secrets = store(legacy: legacy, protected: protected)
        secrets.set("admin-token", "t")
        #expect(secrets.get("password") == "pw")
        #expect(legacy.kept == ["password": "pw", "admin-token": "t"])
        #expect(protected.kept.isEmpty)
        #expect(protected.log.isEmpty)
        #expect(lines.all.isEmpty)
    }

    @Test func aProtectedWriteThatDoesntReadBackFallsBackToTheLegacyStore() {
        let legacy = FakeKeychain()
        let protected = FakeKeychain(dropsWrites: true)
        let secrets = store(legacy: legacy, protected: protected)
        secrets.set("app-key", "k1")
        #expect(legacy.kept["app-key"] == "k1")
        #expect(secrets.get("app-key") == "k1")
        #expect(lines.all.first == "app-key: in the legacy store (the protected store's write didn't read back)")
    }

    @Test func removingTheAppKeyRemovesItFromBoth() {
        let legacy = FakeKeychain(holding: ["app-key": "old"])
        let protected = FakeKeychain(holding: ["app-key": "k1"])
        store(legacy: legacy, protected: protected).set("app-key", nil)
        #expect(legacy.kept.isEmpty)
        #expect(protected.kept.isEmpty)
    }

    // MARK: The move

    @Test func theLegacyAppKeyIsMovedWhenFirstReadThenDeletedFromTheLegacyStore() {
        let legacy = FakeKeychain(holding: ["app-key": "k0"])
        let protected = FakeKeychain()
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.lookup("app-key") == .found("k0"))
        #expect(protected.kept["app-key"] == "k0")
        #expect(legacy.kept["app-key"] == nil)
        // Written, read back, and only then deleted.
        #expect(protected.log == ["lookup app-key", "set app-key", "lookup app-key"])
        #expect(legacy.log == ["lookup app-key", "delete app-key"])
        #expect(lines.all == ["app-key: moved to the protected store, and deleted from the legacy store"])
        // Read from the protected store from then on.
        #expect(secrets.get("app-key") == "k0")
        #expect(legacy.log.count == 2)
    }

    @Test func aMoveThatDoesntReadBackLeavesTheLegacyAppKeyInPlace() {
        let legacy = FakeKeychain(holding: ["app-key": "k0"])
        let protected = FakeKeychain(dropsWrites: true)
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.get("app-key") == "k0")
        #expect(legacy.kept["app-key"] == "k0")
        #expect(!legacy.log.contains("delete app-key"))
        #expect(lines.all == ["app-key: stays in the legacy store (the protected store's write didn't read back)"])
    }

    @Test func anUnreadableProtectedStoreIsSaidSoAndNothingIsMoved() {
        let legacy = FakeKeychain(holding: ["app-key": "k0"])
        let protected = FakeKeychain(unreadable: true)
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.lookup("app-key") == .unreadable("keychain error -25308"))
        #expect(legacy.log.isEmpty)
        #expect(legacy.kept["app-key"] == "k0")
    }

    @Test func theProtectedAppKeyWinsOverALegacyOneLeftBehind() {
        // A build from before, rolled back to, made one in the legacy store.
        let legacy = FakeKeychain(holding: ["app-key": "stale"])
        let protected = FakeKeychain(holding: ["app-key": "k1"])
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.get("app-key") == "k1")
        #expect(legacy.log.isEmpty)
    }

    @Test func noAppKeyAnywhereIsAbsent() {
        let secrets = store(legacy: FakeKeychain(), protected: FakeKeychain())
        #expect(secrets.lookup("app-key") == .absent)
        #expect(lines.all.isEmpty)
    }

    @Test func twoProcessesMovingTheSameKeyAgree() {
        // The app's process and the server agent's, each with its own view of the same keychains.
        let legacy = FakeKeychain(holding: ["app-key": "k0"])
        let protected = FakeKeychain()
        let app = store(legacy: legacy, protected: protected)
        let server = store(legacy: legacy, protected: protected)
        #expect(app.get("app-key") == "k0")
        #expect(server.get("app-key") == "k0")
        #expect(protected.kept["app-key"] == "k0")
        #expect(legacy.kept["app-key"] == nil)
    }
}
}
