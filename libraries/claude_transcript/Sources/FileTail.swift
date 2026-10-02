// A log file as it grows. An agent appends a record at a time; the tail
// reads from where it left off, keeps a partial last line for the next
// read, and hands over whole lines. The kernel says when the file is
// written to; a file that does not exist yet is looked for until it does.

import Foundation

public enum FileTail {
    /// Whole lines newly written, and where they end.
    public struct Batch: Sendable {
        /// The lines' bytes, newlines between them.
        public let data: Data
        /// The byte after the last whole line read: what a reader that
        /// keeps its place writes down.
        public let position: UInt64
    }

    /// What a file holds from `offset` on, as whole lines, in order: what
    /// is there already, then each write as it is made. It is the path
    /// that is followed: a file moved away or replaced is opened again
    /// where it was and read on from the same place, and one that has
    /// become shorter than that place is read again from its start. The
    /// stream runs until whoever reads it stops.
    public static func batches(of url: URL, startingAt offset: UInt64 = 0) -> AsyncStream<Batch> {
        AsyncStream { continuation in
            let following = Task {
                var reader = Reader(url: url, offset: offset)
                while !Task.isCancelled {
                    guard let changes = changes(to: url) else {
                        // Not there yet, and nothing announces a file that
                        // does not exist: looked for again shortly.
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if let batch = reader.read() { continuation.yield(batch) }
                    for await stillThere in changes {
                        // Deleted or moved: the path is opened again.
                        guard stillThere else { break }
                        if let batch = reader.read() { continuation.yield(batch) }
                    }
                }
            }
            continuation.onTermination = { _ in following.cancel() }
        }
    }

    /// The kernel's word on a file: `true` when it has been written to,
    /// `false` once when it is deleted or renamed, after which nothing
    /// more is said. Nil when the file cannot be opened. Writes that come
    /// faster than they are read are one `true`.
    private static func changes(to url: URL) -> AsyncStream<Bool>? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .global(qos: .utility))
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            source.setEventHandler {
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    continuation.yield(false)
                    continuation.finish()
                } else {
                    continuation.yield(true)
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }

    /// Reads on from where the last read stopped.
    private struct Reader {
        let url: URL
        var offset: UInt64
        /// The bytes after the last newline read: a line still being written.
        var partial = Data()

        mutating func read() -> Batch? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            // Truncated: start over.
            if size < offset {
                offset = 0
                partial.removeAll()
            }
            guard size > offset else { return nil }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return nil }
            offset += UInt64(data.count)
            let buffer = partial + data
            // Everything up to the last newline is whole; the rest waits.
            guard let last = buffer.lastIndex(of: 0x0A) else {
                partial = buffer
                return nil
            }
            partial = Data(buffer[buffer.index(after: last)...])
            return Batch(data: Data(buffer[..<last]), position: offset - UInt64(partial.count))
        }
    }
}
