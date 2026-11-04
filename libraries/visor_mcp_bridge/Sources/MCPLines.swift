import Foundation

/// What the agent says on standard input, a line at a time (blank lines
/// left out), read on a thread of its own: a read that waits on the agent
/// holds no thread of Swift's own pool, which in a one-core container is
/// the only one.
enum MCPLines {
    static func standardInput() -> AsyncStream<String> {
        let (lines, arrived) = AsyncStream.makeStream(of: String.self)
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { arrived.yield(trimmed) }
            }
            arrived.finish()
        }
        return lines
    }
}
