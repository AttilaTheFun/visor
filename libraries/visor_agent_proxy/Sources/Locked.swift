// A value shared between threads, under a lock: Synchronization's Mutex,
// held by a class so it can be shared (a Mutex itself can't be copied).
// Shireworks' copy used a lock of Foundation's for its older floor; Visor's
// is macOS 15, Mutex's.

import Synchronization

/// A value read and changed under a lock, from any thread.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<T: Sendable, E: Error>(_ body: (inout Value) throws(E) -> T) throws(E) -> T {
        try mutex.withLock { (value: inout sending Value) throws(E) -> T in try body(&value) }
    }
}
