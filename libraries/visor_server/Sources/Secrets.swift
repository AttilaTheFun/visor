// What the server keeps secret — its password — in the keychain, as a
// generic password under the app's bundle id. The app that wrote it reads
// it without asking, as long as it is signed the same way each build (a
// stable signature, not ad hoc). Tests use a store of their own.

import Foundation
import Security

protocol SecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

final class KeychainSecrets: SecretStore {
    private let service: String
    init(service: String = Bundle.main.bundleIdentifier ?? "Visor Server") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func set(_ key: String, _ value: String?) {
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

final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String?) { values[key] = value }
}
