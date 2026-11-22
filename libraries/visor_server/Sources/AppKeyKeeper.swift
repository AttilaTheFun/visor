// Visor.app's app key (VisorServer.appKey, `X-Visor-App-Key`), kept under
// one name with the server's secrets: the one source of truth that every
// process of the app's reads alike, the app's own and the server's in any
// of its launch contexts (in the app, 0.64's plist agent, the
// SMAppService agent of 0.65).
//
// - The server's process takes the key kept at its start, and makes one
//   (kept at once, and read back) only when there is none. One the
//   keychain can't read is never written over: the server goes on with a
//   key of this run alone, not kept, and says so.
// - Any other process (the app, while the server is the agent) reads the
//   kept key each time it shows it, never a copy of its own from earlier:
//   a server that started since may have made it, or kept it again.
// - The server, when a call at its socket file didn't show its key
//   (VisorServer.isOwnApp), asks again what is kept (`reconciled`): a key
//   kept that isn't its own is taken (the keychain is the truth: another
//   process of the app's made it); none kept, its own is kept again, so
//   the app finds it when it asks again (SocketFileHTTPService retries
//   once its headers changed).
//
// Before 0.66 the agent's key was deleted from the keychain as soon as it
// was written (ProtectedSecrets, why), so the app, reading it from there,
// showed none: Reset Admin Token… and the emergency key rotation were
// refused (403), and with SSH clients off every call of the app's (401).

import Foundation
import Synchronization

/// The app key, as every process of Visor.app's has it.
public final class AppKeyKeeper: Sendable {
    /// Its name among the server's secrets.
    public static let name = "app-key"

    private let secrets: @Sendable () -> any SecretStore
    private let log: @Sendable (String) -> Void
    private let make: @Sendable () -> String
    /// How often an unreadable keychain is asked again at the server's
    /// start, and the wait before each.
    private let attempts: Int
    private let pause: @Sendable () -> Void
    /// The server's own key, in the process that runs it: what it compares
    /// with, and what its own process (the app, with the server in it)
    /// shows. Nil in a process that only shows the key.
    private let own = Mutex<String?>(nil)

    public init(secrets: @escaping @Sendable () -> any SecretStore, log: @escaping @Sendable (String) -> Void,
                make: @escaping @Sendable () -> String = { SecretToken.mint() }, attempts: Int = 5,
                pause: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.5) }) {
        self.secrets = secrets
        self.log = log
        self.make = make
        self.attempts = max(1, attempts)
        self.pause = pause
    }

    /// The server's key at its start: the one kept, else one made and kept
    /// now (never over one the keychain couldn't read).
    public func serverKey() -> String {
        if let held = own.withLock({ $0 }) { return held }
        var why = ""
        for attempt in 0..<attempts {
            if attempt > 0 { pause() }
            switch secrets().lookup(Self.name) {
            case .found(let kept) where !kept.isEmpty:
                return hold(kept)
            case .found, .absent:
                return hold(madeAndKept())
            case .unreadable(let said):
                why = said
            }
        }
        log("app key: the keychain can't be read (\(why)): this run's key isn't kept, and the one kept is left as it is; "
            + "Visor.app's own calls are refused until the server starts again")
        return hold(make())
    }

    /// The key a call at the socket file shows: the server's own in its
    /// process; else the one kept now, read again each time.
    public var shown: String? {
        if let held = own.withLock({ $0 }) { return held }
        guard case .found(let kept) = secrets().lookup(Self.name), !kept.isEmpty else { return nil }
        return kept
    }

    /// The server's key, asked again after a call didn't show `current`:
    /// the one kept if it differs (taken from now on); none kept, `current`
    /// kept again. Nil when there's nothing new to compare with.
    public func reconciled(_ current: String?) -> String? {
        switch secrets().lookup(Self.name) {
        case .found(let kept) where !kept.isEmpty:
            guard kept != current else { return nil }
            log("app key: the one kept isn't the one this server started with (another process of Visor's made it): "
                + "it's taken from now on")
            return hold(kept)
        case .found, .absent:
            guard let current, !current.isEmpty else { return nil }
            secrets().set(Self.name, current)
            let back = secrets().lookup(Self.name) == .found(current)
            log(back ? "app key: none was kept; this server's is kept again, for Visor.app to show"
                : "app key: none was kept, and this server's didn't read back when kept again")
            return nil
        case .unreadable:
            return nil
        }
    }

    private func madeAndKept() -> String {
        let made = make()
        let store = secrets()
        store.set(Self.name, made)
        if store.lookup(Self.name) != .found(made) {
            log("app key: made, but it didn't read back from the keychain: Visor.app can't show it, and its own calls are refused")
        }
        return made
    }

    private func hold(_ key: String) -> String {
        own.withLock { $0 = key }
        return key
    }
}
