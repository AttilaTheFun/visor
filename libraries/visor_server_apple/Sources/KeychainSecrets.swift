import Foundation
import Security
import VisorServer

/// Secrets in the keychain, as generic passwords under the app's bundle id.
/// The app that wrote one reads it without asking, as long as it is signed
/// the same way each build (a stable signature, not ad hoc).
public final class KeychainSecrets: SecretStore {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "Visor Server") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) -> String? {
        guard case .found(let value) = lookup(key) else { return nil }
        return value
    }

    /// Absent only for errSecItemNotFound: any other failure (the keychain
    /// locked, or refusing this build) is unreadable, not absent.
    public func lookup(_ key: String) -> SecretLookup {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else {
            return .unreadable("keychain error \(status): \(SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "unknown")")
        }
        guard let data = result as? Data else { return .unreadable("the keychain item holds no data") }
        return .found(String(decoding: data, as: UTF8.self))
    }

    public func set(_ key: String, _ value: String?) {
        let query = query(key)
        guard let value, !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
