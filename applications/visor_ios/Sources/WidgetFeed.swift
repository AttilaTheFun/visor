// The home screen's widget is fed from here: the latest sessions, as the
// store publishes them, kept where the widget can read them — a keychain
// item in the group the app and the widget share (their entitlements name
// it first, so it is where both look by default; the team's development
// profile allows it) — and the widget told to draw again.

#if os(iOS)
import Foundation
import Security
import VisorServices
import WidgetKit

final class WidgetFeed: VisorWidgetService, @unchecked Sendable {
    static let service = "com.LoganShire.VisorClient.widget"
    static let account = "sessions"

    func publish(_ json: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: Self.account]
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
