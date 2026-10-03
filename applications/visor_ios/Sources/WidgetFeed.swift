// The home screen's widget is fed from here: the latest sessions, as the
// store publishes them, kept where the widget can read them — a keychain
// item in the group the app and the widget share (their entitlements name
// it first, so it is where both look by default; the team's development
// profile allows it) — and the widget told to draw again.

#if os(iOS)
import Foundation
import Security
import VisorClient
import VisorServices
import WidgetKit

@MainActor
final class WidgetFeed: VisorWidgetService {
    static let service = "com.LoganShire.VisorClient.widget"
    static let account = "sessions"

    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: service,
                                               kSecAttrAccount as String: account]

    /// What the widget was last given.
    static func kept() -> String {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A push arrived with a session's state: the widget's sessions are
    /// brought up to date by it, whether or not the app has a connection
    /// (it may have been woken for this alone). Whether anything changed.
    @discardableResult
    func take(push: [String: String]) -> Bool {
        guard let json = WidgetSessions.json(Self.kept(), applying: push) else { return false }
        publish(json)
        return true
    }

    func publish(_ json: String) {
        let query = Self.query
        let data = Data(json.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Readable by the widget while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
