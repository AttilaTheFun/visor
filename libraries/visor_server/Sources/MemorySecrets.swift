import Foundation
import Security

final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String?) { values[key] = value }
}
