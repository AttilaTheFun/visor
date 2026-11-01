import Synchronization

/// A value a test changes while the code under test reads it.
final class Setting<Value: Sendable>: Sendable {
    private let held: Mutex<Value>

    init(_ value: Value) { held = Mutex(value) }

    var value: Value {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }
}
