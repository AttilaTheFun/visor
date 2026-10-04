import Synchronization

/// Secrets held in memory alone, gone with the process: a staging server's
/// and the tests'.
public final class MemorySecrets: SecretStore {
    private let values = Mutex<[String: String]>([:])

    public init() {}

    public func get(_ key: String) -> String? { values.withLock { $0[key] } }

    public func set(_ key: String, _ value: String?) {
        values.withLock { $0[key] = value.flatMap { $0.isEmpty ? nil : $0 } }
    }
}
