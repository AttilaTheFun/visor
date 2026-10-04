import CVisorPOSIX
import Foundation
import Synchronization

/// A connected socket's descriptor, shared by its reader (a thread of its
/// own) and its writer (a queue of its own). Only the reader closes it,
/// once it has read the end; a write never goes to it after that, so a
/// write cannot reach whatever socket the system gives the number to next.
final class POSIXSocket: Sendable {
    let descriptor: Int32
    private let open = Mutex(true)

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Writes all of `data`, or as much as the peer takes before the write
    /// times out (the descriptor's own limit).
    func write(_ data: Data) {
        open.withLock { isOpen in
            guard isOpen else { return }
            writeAll(descriptor, data)
        }
    }

    /// Ends both directions, which wakes the reader; it then closes.
    func shutdown() {
        open.withLock { isOpen in
            if isOpen { visor_shutdown(descriptor) }
        }
    }

    /// The reader's last act.
    func close() {
        open.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            closeDescriptor(descriptor)
        }
    }
}
