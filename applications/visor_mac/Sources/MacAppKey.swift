// The key Visor.app shows at its own server's socket file
// (VisorServer.appKey, `X-Visor-App-Key`): kept with the server's keychain
// items (MacPlaces' server service), which are Visor's processes' alone, so
// another process of this user's, an agent's, can't show it. The server
// makes it the first time it is made, in the app's process or the server
// agent's; the app reads it for each call it makes there (VisorSocketFile's
// services), once there is one.

import Foundation
import Synchronization
import VisorServer

enum MacAppKey {
    static let header = "X-Visor-App-Key"
    private static let name = "app-key"
    /// The key once read, so the keychain is asked once.
    private static let held = Mutex<String?>(nil)

    /// The key kept, made now if there is none: the server's, at its start.
    static func made() -> String {
        if let kept = current { return kept }
        let made = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        ServerPlatform.current.secrets.set(name, made)
        held.withLock { $0 = made }
        return made
    }

    /// The key kept; nil until the server has made one.
    static var current: String? {
        if let held = held.withLock({ $0 }) { return held }
        guard let kept = ServerPlatform.current.secrets.get(name), !kept.isEmpty else { return nil }
        held.withLock { $0 = kept }
        return kept
    }

    /// The header every call at the socket file carries.
    static var headers: [String: String] { current.map { [header: $0] } ?? [:] }
}
