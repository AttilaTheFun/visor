import Foundation
import Security
import VisorServer

/// Secrets in the keychain, as generic passwords under the app's bundle id.
/// With no access group, in the login keychain (a file): the app that wrote
/// one reads it without asking, as long as it is signed the same way each
/// build (a stable signature, not ad hoc), and any other process of the
/// user's may ask for it, which the user is prompted to allow. With one, in
/// the data-protection keychain under that group (KeychainSecrets+DataProtection):
/// only a process signed with the group finds it; any other is told
/// there's nothing, and nobody is asked.
public final class KeychainSecrets: SecretStore {
    private let service: String
    private let accessGroup: String?
    /// In the data-protection keychain with no group named: every group
    /// this process reaches (KeychainSecrets+DataProtection's `anyGroup`).
    private let everyGroup: Bool
    /// Whether an item added to the data-protection keychain stays on this
    /// Mac (the server's: made again on another), or goes with a backup
    /// to another (the client's: its computers' passwords and SSH key).
    private let thisDeviceOnly: Bool

    public init(service: String = Bundle.main.bundleIdentifier ?? "Visor Server", accessGroup: String? = nil, thisDeviceOnly: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        everyGroup = false
        self.thisDeviceOnly = thisDeviceOnly
    }

    init(service: String, everyGroup: Bool) {
        self.service = service
        accessGroup = nil
        self.everyGroup = everyGroup
        thisDeviceOnly = true
    }

    func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        if let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        } else if everyGroup {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The accounts (the keys) of every item kept under the service here:
    /// their names alone, never their values, so nothing is asked of the
    /// user. Empty when there are none, or the keychain won't say.
    public func accounts() -> [String] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        if let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        } else if everyGroup {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        var accounts: [String] = []
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String, !accounts.contains(account) { accounts.append(account) }
        }
        return accounts
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
            // The data-protection keychain's never leave this Mac (a backup
            // restored elsewhere has none): the next start makes them again.
            add[kSecAttrAccessible as String] = (accessGroup == nil && !everyGroup) || !thisDeviceOnly ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
