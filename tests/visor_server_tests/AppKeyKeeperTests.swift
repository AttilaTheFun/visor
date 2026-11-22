// Visor.app's app key as every process of the app's has it (AppKeyKeeper):
// one key, kept, that the server takes at each start whichever process
// runs it (the app's, 0.64's plist agent, 0.65's SMAppService agent), and
// that the app reads, through the update's hand-over from one to the next;
// never a second made beside it, nor one written over a keychain that
// can't be read; and the server asking again when a call didn't show it.
// Each process is its own ProtectedSecrets and AppKeyKeeper over the same
// fake keychains, the legacy one's delete reaching the protected one as a
// Mac's does (0.66: the agent's key was lost as it was kept).

import Synchronization
@testable import VisorServer
import Testing

/// How many keys were made, the waits before asking again, and the lines
/// said.
private final class Made: Sendable {
    private let count = Mutex(0)
    private let paused = Mutex(0)
    private let said = Mutex<[String]>([])
    var keys: Int { count.withLock { $0 } }
    var pauses: Int { paused.withLock { $0 } }
    var lines: [String] { said.withLock { $0 } }
    func make() -> String { "key-" + String(count.withLock { $0 += 1; return $0 }) }
    func pause() { paused.withLock { $0 += 1 } }
    func say(_ line: String) { said.withLock { $0.append(line) } }
}

extension ServerTests {
@Suite final class AppKeyKeeperTests {
    private let made = Made()
    private let protected: FakeKeychain
    private let legacy: FakeKeychain

    init() {
        protected = FakeKeychain(label: "protected")
        legacy = FakeKeychain(reaching: protected, label: "legacy")
    }

    /// A process of Visor.app's: its own view of the keychains, its own
    /// keeper.
    private func process(protected given: FakeKeychain? = nil, attempts: Int = 3) -> AppKeyKeeper {
        let made = made
        let secrets = ProtectedSecrets(legacy: legacy, protected: given ?? protected, names: [AppKeyKeeper.name], log: { _ in })
        return AppKeyKeeper(secrets: { secrets }, log: { made.say($0) }, make: { made.make() }, attempts: attempts,
                            pause: { made.pause() })
    }

    @Test func theHandOverKeepsOneKeyForEveryProcess() {
        // 0.64.1, the server in the app: the key made and kept.
        let inApp = process()
        let key = inApp.serverKey()
        #expect(inApp.shown == key)
        #expect(protected.kept[AppKeyKeeper.name] == key, "kept, not deleted with the legacy copy")
        // ServerAsAgent: 0.64's plist agent takes it; the app, its client, shows it.
        let plistAgent = process()
        #expect(plistAgent.serverKey() == key)
        let app = process()
        #expect(app.shown == key)
        // The update to 0.65.1 restarts the plist agent, then the app hands it to SMAppService.
        #expect(process().serverKey() == key)
        let smAppServiceAgent = process()
        #expect(smAppServiceAgent.serverKey() == key)
        #expect(app.shown == key, "the app still running shows the server's key")
        #expect(process().shown == key, "and so does the app opened again")
        #expect(made.keys == 1, "never a second key")
    }

    @Test func aKeyLeftInTheLegacyStoreIsTakenNotMadeAgain() {
        legacy.set(AppKeyKeeper.name, "from-before")
        #expect(process().serverKey() == "from-before")
        #expect(process().shown == "from-before")
        #expect(protected.kept[AppKeyKeeper.name] == "from-before")
        #expect(legacy.kept[AppKeyKeeper.name] == nil)
        #expect(made.keys == 0)
    }

    @Test func anUnreadableKeychainIsNeverWrittenOver() {
        let locked = FakeKeychain(unreadable: true, holding: [AppKeyKeeper.name: "kept"])
        let key = process(protected: locked, attempts: 3).serverKey()
        #expect(key == "key-1", "a key for this run")
        #expect(locked.kept[AppKeyKeeper.name] == "kept")
        #expect(!locked.log.contains("set \(AppKeyKeeper.name)"))
        #expect(locked.log.filter { $0 == "lookup \(AppKeyKeeper.name)" }.count == 3, "asked again before giving up")
        #expect(made.pauses == 2)
        #expect(made.lines.count == 1 && made.lines[0].hasPrefix("app key: the keychain can't be read"))
    }

    @Test func theServerAskedAgainTakesTheKeptKeyOrKeepsItsOwnAgain() {
        let agent = process()
        let key = agent.serverKey()
        #expect(agent.reconciled(key) == nil, "nothing new")
        // Lost from the keychain (as 0.65.1's agent left it): kept again.
        protected.set(AppKeyKeeper.name, nil)
        let app = process()
        #expect(app.shown == nil)
        #expect(agent.reconciled(key) == nil)
        #expect(protected.kept[AppKeyKeeper.name] == key)
        #expect(app.shown == key)
        // Another process of Visor's kept another since: taken.
        protected.set(AppKeyKeeper.name, "newer")
        #expect(agent.reconciled(key) == "newer")
        #expect(agent.shown == "newer" && agent.serverKey() == "newer")
        #expect(made.keys == 1)
    }
}
}
