import Foundation
import Synchronization

/// Bytes as they come, given back as whole lines: what is left of a line
/// waits for the rest.
final class LineSplitter: Sendable {
    private let pending = Mutex(Data())

    func add(_ data: Data) -> [String] {
        pending.withLock { buffer in
            buffer.append(data)
            var lines: [String] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...end)
            }
            return lines
        }
    }
}
