import CVisorPOSIX
import Foundation
import Synchronization

/// Somewhere the host writes — the agent's input, the server's socket —
/// written on a queue of its own, so a reader that falls behind holds up
/// nothing else. Closed once; nothing is written to it after.
final class Outlet: Sendable {
    private let descriptor: Int32
    private let open = Mutex(true)
    private let queue: DispatchQueue

    init(_ descriptor: Int32, label: String) {
        self.descriptor = descriptor
        queue = DispatchQueue(label: label)
    }

    func write(_ data: Data) {
        queue.async { [self] in
            open.withLock { isOpen in
                guard isOpen else { return }
                writeAll(descriptor, data)
            }
        }
    }

    /// After what was written before it has gone.
    func close() {
        queue.async { [self] in closeNow() }
    }

    /// At once, from any thread: what a reader that has read the end does.
    func closeNow() {
        open.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            Foundation.close(descriptor)
        }
    }

    /// Ends both directions of a socket, which wakes its reader (who then
    /// closes it).
    func shutdown() {
        open.withLock { isOpen in
            if isOpen { visor_shutdown(descriptor) }
        }
    }
}

/// All of `data` to a descriptor, as far as it will take it.
private func writeAll(_ descriptor: Int32, _ data: Data) {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Foundation.write(descriptor, base + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { break }
            offset += written
        }
    }
}
