import Foundation

extension AsyncStream where Element == Data {
    /// The lines of a stream of bytes, each read by `parse` into what it
    /// says (nothing, for a line of no interest). The reading is done off
    /// the caller's actor; only what the lines say crosses over.
    nonisolated func lines<Output: Sendable>(_ parse: @escaping @Sendable (String) -> [Output]) -> AsyncStream<Output> {
        AsyncStream<Output> { continuation in
            let reading = Task {
                var splitter = LineSplitter()
                for await chunk in self {
                    for line in splitter.add(chunk) {
                        for output in parse(line) { continuation.yield(output) }
                    }
                }
                if let line = splitter.rest() {
                    for output in parse(line) { continuation.yield(output) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }
}
