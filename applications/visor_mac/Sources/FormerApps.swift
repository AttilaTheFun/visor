// What Visor on the Mac takes over from the two apps it replaces, Visor
// Server and the Mac client, and keeps where they kept it: their keychain
// items (under each app's bundle id as their service), their message caches
// (each in Application Support under its bundle id; the server's is its
// whole store) and the server's data folder (Application Support/Visor, as
// ServerPlatform.apple has it). Nothing is moved, so the two old apps are
// left as they were. The client's settings alone are copied, from its
// defaults into this app's, which macOS keeps by bundle id.

import Foundation

enum FormerApps {
    /// Visor Server's bundle id: its keychain service and its cache's folder.
    static let server = "com.LoganShire.VisorServer.macOS"
    /// The Mac client's bundle id: the same of its own.
    static let client = "com.LoganShire.VisorClient.macOS"
    /// The client's before that (VisorMacApp.formerBundleID).
    static let earlierClient = "com.LoganShire.Visor.macOS"

    /// The folder in Application Support an app kept its files in.
    static func folder(of bundleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
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
}
