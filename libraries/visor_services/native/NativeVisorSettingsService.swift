#if canImport(Darwin)
import Foundation
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(key: String, value: String) {
        let query = Self.query(key)
        guard !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(query as CFDictionary, update) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

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
