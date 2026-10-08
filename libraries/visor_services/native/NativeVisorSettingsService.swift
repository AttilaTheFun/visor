#if canImport(Darwin)
import Foundation
import os
import Security

@MainActor
public final class NativeVisorSettingsService: VisorSettingsService {
    public init() {}

    /// Secrets in the keychain, a generic password per key under the app's
    /// bundle id. The app that wrote one reads it without asking, as long
    /// as it is signed the same way (a stable signature, not ad hoc).
    public func secret(key: String) -> String {
        var query = Self.query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { Self.problem("read", key, status) }
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(key: String, value: String) {
        let query = Self.query(key)
        guard !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let updated = SecItemUpdate(query as CFDictionary, update)
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            if added != errSecSuccess { Self.problem("add", key, added) }
        } else if updated != errSecSuccess {
            Self.problem("update", key, updated)
        }
    }

    /// A keychain call that failed, in the system log (the item's account
    /// and the status, never its value): what to read when a setting does
    /// not stick.
    private static func problem(_ what: String, _ key: String, _ status: OSStatus) {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
        logger.error("keychain \(what, privacy: .public) \(key, privacy: .public) failed: \(status, privacy: .public) \(message, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.LoganShire.VisorClient", category: "keychain")

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "Visor",
         kSecAttrAccount as String: key]
    }

    public func get(key: String) -> String {
        UserDefaults.standard.string(forKey: "visor." + key) ?? ""
    }

    public func set(key: String, value: String) {
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: "visor." + key) }
        else { UserDefaults.standard.set(value, forKey: "visor." + key) }
    }
}
#endif
