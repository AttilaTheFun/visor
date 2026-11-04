import Foundation
import Synchronization
import VisorProtocol

/// The agent's side: standard output, a message a line, each written whole
/// though calls end on different threads.
final class MCPStandardOutput: MCPOutput {
    private let writing = Mutex(())

    func send(_ message: JSONValue) {
        let line = Array((message.encoded() + "\n").utf8)
        writing.withLock { _ in _ = mcpWriteAll(1, line) }
    }
}
