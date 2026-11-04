// What Visor on the Mac takes over from the two apps it replaces, Visor
// Server and the Mac client, once, into places of its own: their keychain
// items (under each app's bundle id as their service) into this app's two
// services, the server's and the client's; their folders in Application
// Support (each under its bundle id: its message cache, the server's whole
// store) into two of this app's; and the client's settings, from its
// defaults into this app's, which macOS keeps by bundle id. The server's
// data folder (Application Support/Visor, as ServerPlatform.apple has it)
// was always shared. Everything is copied, never moved, so the two old
// apps are left as they were.
//
// Reading another app's keychain item asks the user, once per item, with
// Always Allow: what Logan accepted for the switch (4 Nov 2026). This file
// goes in the release after it (issue #210), and with it what is still
// where the old apps kept it.

import AppKit
import Foundation
import Security

@MainActor
enum FormerApps {
    /// Visor Server's bundle id: its keychain service and its folder.
    static let server = "com.LoganShire.VisorServer.macOS"
    /// The Mac client's bundle id: the same of its own.
    static let client = "com.LoganShire.VisorClient.macOS"
    /// The client's before that (VisorMacApp.formerBundleID).
    static let earlierClient = "com.LoganShire.Visor.macOS"

    /// This app's bundle id, the stem of its own services and folder.
    static var own: String { Bundle.main.bundleIdentifier ?? "com.LoganShire.Visor" }
    /// The keychain service of the server's secrets: apart from the
    /// client's, as they were.
    static var ownServerService: String { own + ".server" }
    /// The keychain service of the client's: the app's own.
    static var ownClientService: String { own }

    /// The folder in Application Support an app kept its files in.
    static func folder(of bundleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// This app's folder for the server's files or the client's.
    static func ownFolder(_ part: String) -> URL {
        folder(of: own).appendingPathComponent(part, isDirectory: true)
    }

    /// The client's settings (the `visor.` keys), copied into this app's
    /// defaults the first time it runs, each only where this app has none.
    /// What the client's defaults hold besides (a launch's arguments, the
    /// system's own) stays there.
    static func adoptClientSettings() {
        let settings = UserDefaults.standard
        guard !settings.bool(forKey: "visor.adoptedFormerApps") else { return }
        settings.set(true, forKey: "visor.adoptedFormerApps")
        for former in [client, earlierClient] {
            let own = Bundle.main.bundleIdentifier.flatMap(settings.persistentDomain(forName:)) ?? [:]
            for (key, value) in settings.persistentDomain(forName: former) ?? [:] where key.hasPrefix("visor.") && own[key] == nil {
                settings.set(value, forKey: key)
            }
        }
    }

    /// The folder to open a cache in: this app's own, once the old app's has
    /// been copied into it. The copy is made while the old app is not
    /// running (its SQLite files shut), into a folder beside it that is
    /// renamed when whole; until it can be, the old app's is used, as
    /// before.
    static func adoptFolder(of former: String, into own: URL) -> URL {
        let files = FileManager.default
        let old = folder(of: former)
        guard !files.fileExists(atPath: own.path), files.fileExists(atPath: old.path) else { return own }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: former).isEmpty else { return old }
        let partial = own.deletingLastPathComponent().appendingPathComponent(own.lastPathComponent + ".copying", isDirectory: true)
        do {
            try files.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: partial)
            try files.copyItem(at: old, to: partial)
            try files.moveItem(at: partial, to: own)
            return own
        } catch {
            try? files.removeItem(at: partial)
            return old
        }
    }

    /// Every secret the old app kept under `former`, copied under `own`,
    /// each only where `own` has none. Reading one asks the user once (it
    /// is another app's); the ones a user refuses are left, and the copy is
    /// not tried again. One the keychain cannot give now (locked, no user
    /// to ask) is tried at the next launch.
    static func adoptKeychain(from former: String, into own: String) {
        let flag = "visor.adoptedKeychain." + former
        let settings = UserDefaults.standard
        guard !settings.bool(forKey: flag) else { return }
        var finished = true
        for account in accounts(under: former) where !exists(account, under: own) {
            switch read(account, under: former) {
            case .found(let data):
                add(data, account, under: own)
            case .refused, .missing:
                break
            case .unavailable:
                finished = false
            }
        }
        if finished { settings.set(true, forKey: flag) }
    }

    private enum Read {
        case found(Data)
        case refused
        case missing
        case unavailable
    }

    /// The accounts of a service's generic passwords: their attributes
    /// alone, which the keychain gives without asking.
    private static func accounts(under service: String) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func exists(_ account: String, under service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func read(_ account: String, under service: String) -> Read {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return (result as? Data).map(Read.found) ?? .missing
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed:
            return .refused
        default:
            return .unavailable
        }
    }

    private static func add(_ data: Data, _ account: String, under service: String) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }
}
