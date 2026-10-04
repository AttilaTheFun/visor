import Foundation
import Synchronization
import WinSDK

/// A connected socket, shared by its reader (a thread of its own) and its
/// writer (a queue of its own). Only the reader closes it, once it has read
/// the end; nothing is written to it after that.
final class WinsockSocket: Sendable {
    let handle: SOCKET
    private let open = Mutex(true)

    init(_ handle: SOCKET) {
        self.handle = handle
    }

    func write(_ data: Data) {
        open.withLock { isOpen in
            if isOpen { sendAll(handle, data) }
        }
    }

    func shutdown() {
        open.withLock { isOpen in
            if isOpen { shutdownSocket(handle) }
        }
    }

    func close() {
        open.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            closeSocket(handle)
        }
    }
}
