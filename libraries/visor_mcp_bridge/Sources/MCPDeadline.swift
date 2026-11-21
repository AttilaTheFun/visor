import Synchronization

/// Work given a limit: its result, or nil once the limit passes first. The
/// work isn't stopped (a call on a socket the server hasn't answered ends
/// when the server answers or closes it); no one waits on it any longer.
enum MCPDeadline {
    static func first<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            let once = Once(done)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.finish(nil)
            }
            Task {
                let value = await work()
                timer.cancel()
                once.finish(value)
            }
        }
    }

    /// A continuation resumed by whichever comes first, once.
    private final class Once<T: Sendable>: Sendable {
        private let waiting: Mutex<CheckedContinuation<T?, Never>?>

        init(_ continuation: CheckedContinuation<T?, Never>) {
            waiting = Mutex(continuation)
        }

        func finish(_ value: T?) {
            let continuation = waiting.withLock { waiting in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume(returning: value)
        }
    }
}
