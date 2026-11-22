// Which store a secret is kept in, and the move between them (visor#471's
// follow-up): Visor.app's app key in the protected store (the Mac's
// data-protection keychain under its own access group) when the build has
// one, else in the legacy store (the login keychain), as the log says;
// moved over the first time it's read: deleted from the legacy store
// first, then written to the protected store and read back (a Mac's delete
// from the login keychain reaches the data-protection keychain too, so
// deleting after took the new copy with it: 0.66). Fake keychains stand in
// for both, the legacy one reaching the protected one as a Mac's does.

import Synchronization
@testable import VisorServer
import Testing

/// The lines a store logs.
private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

extension ServerTests {
@Suite final class ProtectedSecretsTests {
    private let lines = Lines()

    private func store(legacy: FakeKeychain, protected: FakeKeychain?, elsewhere: [FakeKeychain] = [],
                       unprotected: String = "") -> ProtectedSecrets {
        let lines = lines
        return ProtectedSecrets(legacy: legacy, protected: protected, elsewhere: elsewhere, names: ["app-key"],
                                unprotected: unprotected, log: { lines.add($0) })
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

    @Test func theLegacyAppKeyIsMovedWhenFirstReadDeletedThereFirst() {
        let journal = Journal()
        let protected = FakeKeychain(journal: journal, label: "protected")
        let legacy = FakeKeychain(holding: ["app-key": "k0"], reaching: protected, journal: journal, label: "legacy")
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.lookup("app-key") == .found("k0"))
        #expect(protected.kept["app-key"] == "k0", "still there: the legacy delete came before the write")
        #expect(legacy.kept["app-key"] == nil)
        #expect(journal.all == ["legacy delete app-key", "protected set app-key"])
        #expect(protected.log == ["lookup app-key", "set app-key", "lookup app-key"])
        #expect(lines.all == ["app-key: moved to the protected store from the legacy store"])
        // Read from the protected store from then on.
        #expect(secrets.get("app-key") == "k0")
        #expect(legacy.log.count == 2)
    }

    @Test func aMoveThatDoesntReadBackPutsTheLegacyAppKeyBack() {
        let legacy = FakeKeychain(holding: ["app-key": "k0"])
        let protected = FakeKeychain(dropsWrites: true)
        let secrets = store(legacy: legacy, protected: protected)
        #expect(secrets.get("app-key") == "k0")
        #expect(legacy.kept["app-key"] == "k0")
        #expect(protected.kept.isEmpty)
        #expect(lines.all == ["app-key: stays in the legacy store (the protected store's write didn't read back)"])
    }

    // MARK: A Mac's legacy delete, which reaches the protected store

    /// 0.66: the key kept was deleted with the legacy copy as it was
    /// written, so it lived in the writing process alone.
    @Test func aKeyWrittenStaysKeptThoughTheLegacyDeleteReachesTheProtectedStore() {
        let journal = Journal()
        let protected = FakeKeychain(journal: journal, label: "protected")
        let legacy = FakeKeychain(reaching: protected, journal: journal, label: "legacy")
        let secrets = store(legacy: legacy, protected: protected)
        secrets.set("app-key", "k1")
        #expect(protected.kept["app-key"] == "k1")
        #expect(journal.all == ["legacy delete app-key", "protected set app-key"])
        // Another process's view of the same keychains finds it.
        #expect(store(legacy: legacy, protected: protected).get("app-key") == "k1")
    }

    @Test func aStaleLegacyCopyIsReplacedNotLeftBeside() {
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: ["app-key": "stale"], reaching: protected)
        store(legacy: legacy, protected: protected).set("app-key", "k1")
        #expect(protected.kept["app-key"] == "k1")
        #expect(legacy.kept["app-key"] == nil)
    }

    // MARK: Elsewhere

    @Test func aKeyUnderAnotherGroupIsMovedNotMadeAgain() {
        let protected = FakeKeychain()
        let other = FakeKeychain(holding: ["app-key": "k-other"])
        let legacy = FakeKeychain(holding: ["app-key": "k-legacy"], reaching: protected)
        let secrets = store(legacy: legacy, protected: protected, elsewhere: [other])
        #expect(secrets.get("app-key") == "k-other")
        #expect(protected.kept["app-key"] == "k-other")
        #expect(other.kept.isEmpty)
        #expect(lines.all == ["app-key: moved to the protected store from another access group"])
        #expect(secrets.get("app-key") == "k-other")
    }

    @Test func aMoveFromAnotherGroupThatDoesntReadBackLeavesItThere() {
        let other = FakeKeychain(holding: ["app-key": "k-other"])
        let secrets = store(legacy: FakeKeychain(), protected: FakeKeychain(dropsWrites: true), elsewhere: [other])
        #expect(secrets.get("app-key") == "k-other")
        #expect(other.kept["app-key"] == "k-other")
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

    // MARK: The client's items (0.66, before Visor.app is sandboxed): copied, the legacy copies kept

    /// Every item under the client's service, protected, the legacy
    /// store's copies kept for a rollback.
    private func client(legacy: FakeKeychain, protected: FakeKeychain?) -> ProtectedSecrets {
        let lines = lines
        return ProtectedSecrets(legacy: legacy, protected: protected, protecting: { _ in true }, keepsLegacy: true, log: { lines.add($0) })
    }

    private let clientItems = ["password.s1": "pw1", "password.s2": "pw2", "ssh.key": "k", "computers": "[]"]

    /// What a legacy store was asked: lookups alone, never a set or a delete.
    private func onlyRead(_ legacy: FakeKeychain) -> Bool { legacy.log.allSatisfy { $0.hasPrefix("lookup ") } }

    /// NCH's review of #503: a build rolled back to reads the login
    /// keychain alone, so its copies stay; and the protected copies survive,
    /// though the legacy store's delete would reach them, since there's none.
    @Test func theClientsItemsAreCopiedTheLegacyCopiesKeptAndTheProtectedOnesSurvive() {
        let journal = Journal()
        let protected = FakeKeychain(journal: journal, label: "protected")
        let legacy = FakeKeychain(holding: clientItems, reaching: protected, journal: journal, label: "legacy")
        let keys = clientItems.keys.sorted()
        client(legacy: legacy, protected: protected).moveAll(keys)
        #expect(protected.kept == clientItems)
        #expect(legacy.kept == clientItems, "the login keychain's copies kept, for a rollback")
        #expect(onlyRead(legacy), "no delete or update asked of the legacy store")
        #expect(journal.all == keys.map { "protected set \($0)" })
        #expect(Set(lines.all) == Set(keys.map { "\($0): copied to the protected store from the legacy store, which keeps its copy" }))
        // The sandboxed release, reading the group alone, finds them; a
        // rollback, reading the login keychain alone, finds them too.
        let sandboxed = client(legacy: FakeKeychain(), protected: protected)
        for (key, value) in clientItems {
            #expect(sandboxed.get(key) == value)
            #expect(legacy.get(key) == value)
        }
    }

    @Test func aClientItemsReadPrefersTheProtectedOne() {
        let legacy = FakeKeychain(holding: ["password.s1": "stale"])
        let protected = FakeKeychain(holding: ["password.s1": "pw1"])
        #expect(client(legacy: legacy, protected: protected).get("password.s1") == "pw1")
        #expect(legacy.log.isEmpty, "the login keychain isn't asked")
    }

    @Test func aClientItemLeftBehindIsCopiedWhenRead() {
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: ["ssh.key": "k"], reaching: protected)
        let secrets = client(legacy: legacy, protected: protected)
        #expect(secrets.get("ssh.key") == "k")
        #expect(protected.kept["ssh.key"] == "k")
        #expect(legacy.kept["ssh.key"] == "k")
        #expect(onlyRead(legacy))
    }

    @Test func aClientItemWrittenGoesToTheProtectedStoreAlone() {
        let journal = Journal()
        let protected = FakeKeychain(journal: journal, label: "protected")
        let legacy = FakeKeychain(holding: ["password.s1": "old"], reaching: protected, journal: journal, label: "legacy")
        let secrets = client(legacy: legacy, protected: protected)
        secrets.set("password.s1", "new")
        #expect(protected.kept["password.s1"] == "new")
        #expect(legacy.kept["password.s1"] == "old", "left as it was: stale from now on")
        #expect(journal.all == ["protected set password.s1"])
        #expect(onlyRead(legacy))
        #expect(secrets.get("password.s1") == "new")
    }

    /// A computer forgotten stays forgotten: its legacy copy, kept, isn't
    /// copied back by the next read.
    @Test func aClientItemRemovedIsntBroughtBackFromItsLegacyCopy() {
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: ["password.s1": "pw1"], reaching: protected)
        let secrets = client(legacy: legacy, protected: protected)
        #expect(secrets.get("password.s1") == "pw1")
        secrets.set("password.s1", nil)
        #expect(protected.kept["password.s1"] == nil)
        #expect(legacy.kept["password.s1"] == "pw1", "kept for a rollback")
        #expect(onlyRead(legacy))
        #expect(secrets.get("password.s1") == nil)
        #expect(client(legacy: legacy, protected: protected).get("password.s1") == nil, "nor by another process")
        #expect(protected.kept[ProtectedSecrets.forgottenName]?.contains("pw1") == false, "its hash noted, never the value")
        // Written again: kept, and no longer forgotten.
        secrets.set("password.s1", "pw1")
        #expect(secrets.get("password.s1") == "pw1")
        secrets.set("password.s1", nil)
        #expect(secrets.get("password.s1") == nil)
    }

    /// A build rolled back to wrote another value since (the computer added
    /// again there): that one is copied.
    @Test func aDifferentLegacyValueAfterARemovalIsCopied() {
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: ["password.s1": "pw1"], reaching: protected)
        let secrets = client(legacy: legacy, protected: protected)
        secrets.set("password.s1", nil)
        legacy.set("password.s1", "pw2")
        #expect(secrets.get("password.s1") == "pw2")
        #expect(protected.kept["password.s1"] == "pw2")
    }

    @Test func aCopyThatDoesntReadBackLeavesTheLegacyCopiesAlone() {
        let protected = FakeKeychain(dropsWrites: true)
        let legacy = FakeKeychain(holding: clientItems, reaching: protected)
        let secrets = client(legacy: legacy, protected: protected)
        secrets.moveAll(clientItems.keys.sorted())
        #expect(legacy.kept == clientItems)
        #expect(onlyRead(legacy))
        #expect(protected.kept.isEmpty)
        for (key, value) in clientItems { #expect(secrets.get(key) == value) }
    }

    @Test func withNoProtectedStoreNothingIsCopied() {
        let legacy = FakeKeychain(holding: clientItems)
        let secrets = client(legacy: legacy, protected: nil)
        secrets.moveAll(clientItems.keys.sorted())
        #expect(legacy.log.isEmpty)
        #expect(legacy.kept == clientItems)
        #expect(secrets.get("password.s1") == "pw1")
    }

    @Test func copyingAgainAsksTheLegacyStoreNothing() {
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: clientItems, reaching: protected)
        let secrets = client(legacy: legacy, protected: protected)
        secrets.moveAll(clientItems.keys.sorted())
        let calls = legacy.log.count
        secrets.moveAll(clientItems.keys.sorted() + [ProtectedSecrets.forgottenName])
        #expect(legacy.log.count == calls, "read from the protected store alone")
        #expect(protected.kept == clientItems)
    }

    /// The server's move (#502) is as it was: the legacy copy deleted first.
    @Test func theServersMoveIsUnchanged() {
        let journal = Journal()
        let protected = FakeKeychain(journal: journal, label: "protected")
        let legacy = FakeKeychain(holding: ["app-key": "k0"], reaching: protected, journal: journal, label: "legacy")
        store(legacy: legacy, protected: protected).moveAll(["app-key"])
        #expect(journal.all == ["legacy delete app-key", "protected set app-key"])
        #expect(protected.kept["app-key"] == "k0")
        #expect(legacy.kept["app-key"] == nil)
    }

    @Test func twoProcessesMovingTheSameKeyAgree() {
        // The app's process and the server agent's, each with its own view of the same keychains.
        let protected = FakeKeychain()
        let legacy = FakeKeychain(holding: ["app-key": "k0"], reaching: protected)
        let app = store(legacy: legacy, protected: protected)
        let server = store(legacy: legacy, protected: protected)
        #expect(app.get("app-key") == "k0")
        #expect(server.get("app-key") == "k0")
        #expect(protected.kept["app-key"] == "k0")
        #expect(legacy.kept["app-key"] == nil)
    }
}
}
