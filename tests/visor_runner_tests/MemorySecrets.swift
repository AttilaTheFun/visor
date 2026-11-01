import Synchronization
import VisorRunner

/// The Runner's secrets, kept in memory.
final class MemorySecrets: RunnerSecrets {
    private let values = Mutex<[String: String]>([:])

    func value(_ name: String) -> String? { values.withLock { $0[name] } }

    func set(_ name: String, _ value: String?) { values.withLock { $0[name] = value } }

    var all: [String: String] { values.withLock { $0 } }
}
