// Where Visor Client keeps its secrets (its computers, their passwords,
// this device's key): the data-protection keychain, under the app's own
// access group (`<team>.com.LoganShire.VisorClient.macOS`), where the build
// has one (a Developer ID build, with its profile), so the sandbox's
// secrets are the app's alone and go with Forget Everything. Without the
// group (a build signed ad hoc) they stay in the login keychain, as
// Visor.app's app key does (applications/visor_mac, Sources/MacSecrets.swift).

#if os(macOS)
import Foundation
import Security
import VisorServices

enum ClientKeychain {
    /// This build's own keychain access group, from its signature's
    /// entitlements, when the keychain takes it; nil without one, or when
    /// the keychain refuses it (no profile granting it:
    /// errSecMissingEntitlement).
    static func ownGroup() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier, let task = SecTaskCreateFromSelf(nil) else { return nil }
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] ?? []
        let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
        guard let group = VisorKeychainGroup.own(bundleID: bundleID, groups: groups, applicationIdentifier: identifier) else {
            return nil
        }
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bundleID,
                                    kSecAttrAccount as String: "probe", kSecAttrAccessGroup as String: group,
                                    kSecUseDataProtectionKeychain as String: true]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            NSLog("Visor: the data-protection keychain refused %@ (%d): secrets in the login keychain", group, status)
            return nil
        }
        return group
    }
}
#endif
