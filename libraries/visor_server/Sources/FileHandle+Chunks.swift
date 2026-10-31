import Foundation

extension FileHandle {
    /// What the other end of a pipe writes, as it writes it; the stream
    /// ends when that end closes. Read on a thread of its own, blocking: a
    /// dispatch source on the descriptor (`readabilityHandler`) went
    /// unheard on Linux once an earlier one, on a descriptor closed under
    /// it, had held the same number, and its reader waited for an end that
    /// had come.
    var chunks: AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread { [self] in
                while true {
                    let data = availableData
                    if data.isEmpty { break }
                    continuation.yield(data)
                }
                continuation.finish()
            }
            thread.start()
        }
    }
}
