import Foundation
import Synchronization

/// A descriptor used from more than one thread and closed by one of them:
/// once it is closed nothing more is done with it, so nothing reaches
/// whatever the system gives the number to next.
final class GuardedDescriptor: Sendable {
    let number: Int32
    private let open = Mutex(true)

    init(_ number: Int32) {
        self.number = number
    }

    /// Does `body` with it, if it is still open.
    func use(_ body: (Int32) -> Void) {
        open.withLock { isOpen in
            if isOpen { body(number) }
        }
    }

    func close() {
        open.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            closeDescriptor(number)
        }
    }
}
