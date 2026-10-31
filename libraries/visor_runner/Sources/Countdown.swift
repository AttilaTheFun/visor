import Synchronization

/// Runs `then` once `count` threads have each said they are done.
final class Countdown: Sendable {
    private let left: Mutex<Int>
    private let then: @Sendable () -> Void

    init(_ count: Int, then: @escaping @Sendable () -> Void) {
        left = Mutex(count)
        self.then = then
    }

    func done() {
        let last = left.withLock { count -> Bool in
            count -= 1
            return count == 0
        }
        if last { then() }
    }
}
