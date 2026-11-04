// The raw calls on a socket's descriptor, as free functions: inside a type
// that has a `close` of its own, the system's is out of reach by name, and
// naming its module differs between systems (as visor_server_posix's
// Descriptors.swift).

import Foundation

/// All of `bytes` to a descriptor; false when it took less.
func mcpWriteAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = write(descriptor, base + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

/// What the next read gives: bytes, or nil at the end (or an error).
func mcpRead(_ descriptor: Int32, into buffer: inout [UInt8]) -> Int? {
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        return count > 0 ? count : nil
    }
}

func mcpClose(_ descriptor: Int32) {
    _ = close(descriptor)
}
