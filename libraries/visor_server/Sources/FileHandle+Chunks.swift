import Foundation

extension FileHandle {
    /// What the other end of a pipe writes, as it writes it; the stream
    /// ends when that end closes.
    var chunks: AsyncStream<Data> {
        AsyncStream { continuation in
            readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        }
    }
}
