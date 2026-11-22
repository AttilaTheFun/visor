// The data-protection keychain, under this app's own keychain access group:
// `<team>.<bundle id>`, which a build signed with its Developer ID profile
// carries (its `keychain-access-groups`, written `$(AppIdentifierPrefix)…`
// and made the team's as it's signed). The team is read from this
// process's own signature, never written down: its `keychain-access-groups`
// entitlement, else its `com.apple.application-identifier`, which macOS
// also takes as one of its groups. A build without either (signed ad hoc,
// or by hand without the profile) has no group of its own, and its secrets
// stay in the login keychain.

import Foundation
import Security

extension KeychainSecrets {
    /// The data-protection keychain's store for `service` under this
    /// process's own group for `bundleID`, or nil and why there's none.
    /// `thisDeviceOnly`: its items stay on this Mac (KeychainSecrets).
    public static func dataProtection(service: String, bundleID: String, thisDeviceOnly: Bool = true) -> (store: KeychainSecrets?, why: String) {
        guard let group = ownAccessGroup(bundleID: bundleID) else {
            return (nil, "this build is signed with no keychain access group of its own (ad hoc, or without its Developer ID profile)")
        }
        let store = KeychainSecrets(service: service, accessGroup: group, thisDeviceOnly: thisDeviceOnly)
        // A group the signature claims but the keychain refuses (no profile
        // granting it: errSecMissingEntitlement) is no store.
        var probe = store.query("probe")
        probe[kSecReturnData as String] = false
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "unknown"
            return (nil, "the data-protection keychain refused this build's access group (\(status): \(message))")
        }
        return (store, "")
    }

    /// The data-protection keychain's store for `service` in every access
    /// group this process reaches, its own among them: where a protected
    /// secret left under another group of the app's is found, to be moved
    /// to its own (ProtectedSecrets' `elsewhere`) rather than made again.
    public static func anyGroup(service: String) -> KeychainSecrets {
        KeychainSecrets(service: service, everyGroup: true)
    }

    /// This process's own keychain access group for `bundleID`
    /// (`<team>.<bundle id>`), from its signature's entitlements; nil
    /// without one.
    static func ownAccessGroup(bundleID: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] ?? []
        let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
        return ownGroup(bundleID: bundleID, groups: groups, applicationIdentifier: identifier)
    }

    /// The group of `groups`, else the application identifier, that is
    /// `<prefix>.<bundle id>`.
    static func ownGroup(bundleID: String, groups: [String], applicationIdentifier: String?) -> String? {
        let own = { (group: String) in group.hasSuffix("." + bundleID) && group.count > bundleID.count + 1 }
        return groups.first(where: own) ?? applicationIdentifier.flatMap { own($0) ? $0 : nil }
    }
}
