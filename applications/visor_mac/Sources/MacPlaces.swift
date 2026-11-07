// Where Visor on the Mac keeps what is its own: the server's secrets and the
// client's under two keychain services, and their caches in two folders of
// Application Support, each under this app's bundle id. The server's data
// folder (Application Support/Visor, as ServerPlatform.apple has it) is
// apart from these.

import Foundation

enum MacPlaces {
    /// This app's bundle id, the stem of its services and its folder.
    static var own: String { Bundle.main.bundleIdentifier ?? "com.LoganShire.Visor" }
    /// The keychain service of the server's secrets: apart from the
    /// client's.
    static var serverService: String { own + ".server" }
    /// The keychain service of the client's: the app's own.
    static var clientService: String { own }

    /// This app's folder for the server's files or the client's.
    static func folder(_ part: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(own, isDirectory: true)
            .appendingPathComponent(part, isDirectory: true)
    }
}
