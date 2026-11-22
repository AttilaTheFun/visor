// A value shared between threads, under a lock: Synchronization's Mutex,
// held by a class so a closure can share it (a Mutex itself can't be
// copied), as agent-proxy's Locked. gh_mcp's used Foundation's locks.

import Synchronization

/// A value read and changed under a lock, from any thread.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<T: Sendable, E: Error>(_ body: (inout Value) throws(E) -> T) throws(E) -> T {
        try mutex.withLock { (value: inout sending Value) throws(E) -> T in try body(&value) }
    }
}
