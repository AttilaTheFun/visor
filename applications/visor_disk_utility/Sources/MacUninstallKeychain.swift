// Visor's keychain items as Uninstall… finds and deletes them
// (UninstallKeychain): generic passwords by service, in the login keychain
// or, under Visor's own access group, the data-protection keychain, where
// the app key is. Visor Disk Utility reaches that group only as a build
// signed with it (its Developer ID profile, as Visor.app's: BUILD.bazel);
// `ownAccessGroup` is nil otherwise, and the plan says so.

import Foundation
import Security
import VisorUninstall

struct MacUninstallKeychain: UninstallKeychain {
    /// Visor's keychain access group (`<team>.com.LoganShire.Visor`) among
    /// this process's own entitlements, read from its signature (never
    /// written down); nil without it.
    static func ownAccessGroup(bundleID: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] ?? []
        return groups.first { $0.hasSuffix("." + bundleID) && $0.count > bundleID.count + 1 }
    }

    private func query(service: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let accessGroup {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func accounts(service: String, accessGroup: String?) -> [String] {
        var query = query(service: service, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// The service's items of these accounts deleted; what went wrong, by
    /// account.
    func delete(service: String, accessGroup: String?, accounts: [String]) -> [String] {
        accounts.compactMap { account in
            var query = query(service: service, accessGroup: accessGroup)
            query[kSecAttrAccount as String] = account
            let status = SecItemDelete(query as CFDictionary)
            guard status != errSecSuccess, status != errSecItemNotFound else { return nil }
            return "\(account): \(SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)")"
        }
    }
}
