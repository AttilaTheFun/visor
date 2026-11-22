// The calls to several fake keychains, in the order they came
// (FakeKeychain).

import Synchronization

/// The calls to several keychains, in order.
final class Journal: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}
