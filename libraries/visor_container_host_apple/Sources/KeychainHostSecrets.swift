import Foundation
import Security
import VisorContainerHost

/// A container server's secrets in the keychain, as generic passwords: the
/// host's bundle id the service, the server's id and the secret's name the
/// account. The host that wrote one reads it without asking, as long as it
/// is signed the same way each build (Developer ID, notarized).
public struct KeychainHostSecrets: HostSecrets {
    private let service: String
    private let server: String

    public init(server: String, service: String = Bundle.main.bundleIdentifier ?? "visor-container-host") {
        self.server = server
        self.service = service
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(server) \(name)"]
    }

    public func value(_ name: String) -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ name: String, _ value: String?) throws {
        let query = query(name)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// The keychain's refusal, in its own words.
    struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String {
            "The keychain refused: \((SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)")"
        }
    }
}
