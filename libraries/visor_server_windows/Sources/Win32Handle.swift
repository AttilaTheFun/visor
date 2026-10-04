import Synchronization
import WinSDK

/// A Win32 handle used from more than one thread and closed by one of
/// them: carried as its value, and once closed nothing more is done with
/// it.
final class Win32Handle: Sendable {
    private let value: UInt
    private let open = Mutex(true)

    init(_ handle: HANDLE) {
        value = UInt(bitPattern: handle)
    }

    /// The handle, for a call that only this thread makes while it is open
    /// (the reader of a pipe, the waiter on a process).
    var handle: HANDLE { HANDLE(bitPattern: value)! }

    /// Does `body` with it, if it is still open.
    func use(_ body: (HANDLE) -> Void) {
        open.withLock { isOpen in
            if isOpen { body(handle) }
        }
    }

    /// Closes it once, with `closing` (CloseHandle unless said otherwise).
    func close(_ closing: (HANDLE) -> Void = { _ = CloseHandle($0) }) {
        open.withLock { isOpen in
            guard isOpen else { return }
            isOpen = false
            closing(handle)
        }
    }
}
