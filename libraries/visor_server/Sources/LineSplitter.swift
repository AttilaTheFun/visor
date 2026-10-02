import Foundation

/// Bytes into whole lines: a partial last line waits for the bytes that
/// finish it.
struct LineSplitter {
    private var buffer = Data()

    mutating func add(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { lines.append(text) }
        }
        return lines
    }

    /// What was written after the last newline, when the stream has ended.
    mutating func rest() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
