// Settings in UserDefaults, and secrets in the keychain where there is one
// (Apple's systems); elsewhere (a host's own Foundation, on the web and
// Android) secrets are kept with the settings, as the system keeps an
// app's own preferences. A launch's own settings (VisorLaunchSettings: the
// fixture's and the account's, never a secret) come first from the
// environment, as `visor.<key>` alone (as Isomer's launchers give a test's:
// on the iPhone's simulator, through simctl's SIMCTL_CHILD_), then from
// UserDefaults, where the iPhone's `-visor.<key> <value>` launch arguments
// put them.

import Foundation
#if canImport(os)
import os
#endif
#if canImport(Security)
import Security
#endif

@MainActor
public final class NativeVisorSettingsService: VisorSettingsService {
    /// The keychain service secrets are kept under: the app's bundle id,
    /// unless the app says otherwise (Visor on the Mac keeps the one the
    /// client had before it was merged into it).
    private let keychainService: String
    /// The keychain access group secrets are kept in (`<team>.<group>`, one
    /// of the app's `keychain-access-groups`), for apps that share them; nil
    /// for the app's default group. On the Mac a group is the data
    /// protection keychain's, not the login keychain's.
    private let keychainGroup: String?
    /// The launch's settings from its environment (`visor.fixture=snapshot`;
    /// a bare `fixture` or `account` is someone else's), read once: none in
    /// a launch of the app's own.
    private var launch: [String: String]
    /// Where the settings are kept: the app's own UserDefaults, which its
    /// launch arguments also fill.
    private let defaults: UserDefaults

    /// `environment` and `defaults` are the process's own, unless a test
    /// gives others.
    public init(keychainService: String? = nil, keychainGroup: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                defaults: UserDefaults = .standard) {
        self.keychainService = keychainService ?? Bundle.main.bundleIdentifier ?? "Visor"
        self.keychainGroup = keychainGroup
        self.defaults = defaults
        launch = VisorLaunchSettings.values(in: environment, prefix: VisorLaunchSettings.prefix)
    }

    public func get(key: String) -> String {
        launch[key] ?? defaults.string(forKey: "visor." + key) ?? ""
    }

    public func set(key: String, value: String) {
        // What the app sets stands over what it was launched with.
        launch[key] = nil
        if value.isEmpty { defaults.removeObject(forKey: "visor." + key) }
        else { defaults.set(value, forKey: "visor." + key) }
    }

    #if canImport(Security)
    /// Secrets in the keychain, a generic password per key under the app's
    /// bundle id. The app that wrote one reads it without asking, as long
    /// as it is signed the same way (a stable signature, not ad hoc).
    public func secret(key: String) -> String {
        var query = self.query(key)
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
        let query = self.query(key)
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

    private func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: key]
        if let keychainGroup {
            query[kSecAttrAccessGroup as String] = keychainGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
    #else
    /// Secrets with the settings, under a name of their own.
    public func secret(key: String) -> String { get(key: "secret." + key) }

    public func setSecret(key: String, value: String) { set(key: "secret." + key, value: value) }
    #endif
}
