// The raw calls on descriptors and processes, as free functions: inside a
// type that has a `write`, `close` or `kill` of its own, the system's are
// out of reach by name, and naming their module differs between systems.

import Foundation

/// All of `data` to a descriptor, as far as it will take it.
func writeAll(_ descriptor: Int32, _ data: Data) {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = write(descriptor, base + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { break }
            offset += written
        }
    }
}

func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

/// A signal to a process.
func signalProcess(_ pid: Int32, _ signal: Int32) {
    _ = kill(pid, signal)
}

/// Whether a process with this id exists (signal 0 asks without sending).
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}
