import Synchronization

/// An `approve` call the person may still answer: whether it was given up
/// on (and why), and how to stop the wait, which withdraws the prompt.
package final class MCPAsking: Sendable {
    private struct State {
        var reason: String?
        var stop: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// Why it was given up on, once it was.
    package var reason: String? { state.withLock { $0.reason } }

    /// Gives up on the call, once: what stops its wait is run.
    package func cancel(_ reason: String) {
        let stop: (@Sendable () -> Void)? = state.withLock { state in
            guard state.reason == nil else { return nil }
            state.reason = reason
            return state.stop
        }
        stop?()
    }

    /// What stops the wait, set once it can be stopped; false when the
    /// call was given up on already (the caller stops it itself).
    package func whenCancelled(_ stop: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.reason == nil else { return false }
            state.stop = stop
            return true
        }
    }
}
