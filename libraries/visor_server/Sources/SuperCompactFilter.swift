// Super Compact's prefilter (docs/super-compact.md): a Claude Code
// conversation, which can be over 2 GB, streamed a piece at a time — never
// read whole — and what matters of it kept, in order, as plain text
// (SuperCompactFilter+Lines): the person's words, the agent's replies,
// Claude's own compaction summaries, each tool call as a line, each tool
// result's first lines, mail as a line, and when each was. The text is
// written in chunks of about the map's size, a file each, never cutting
// an entry in two.

import Foundation

enum SuperCompactFilter {
    /// What a prefilter made: how many chunk files, the characters (UTF-8
    /// bytes) they hold, and the file's lines read.
    struct Outcome: Codable, Equatable, Sendable {
        var chunks: Int
        var characters: Int
        var lines: Int
    }

    /// Why a prefilter stopped short.
    enum Failure: Error, Equatable {
        case unreadable(String)
        case stopped
    }

    /// The chunk files' folder in a job's folder, and each one's name.
    static let chunksFolder = "chunks"
    static func chunkName(_ index: Int) -> String { String(format: "%04d.txt", index) }

    /// `source` read to `limit` bytes (the snapshot: its whole lines when
    /// the job began), `readSize` bytes at a time, its kept text written
    /// into `folder` as chunks of about `chunkCharacters`. A line not
    /// ended by `limit` is one being written, and not taken. `stop` is
    /// asked between reads: true ends it (`Failure.stopped`).
    @concurrent
    static func run(source: URL, limit: Int, into folder: URL, chunkCharacters: Int, readSize: Int = 4 << 20,
                    stop: @escaping @Sendable () -> Bool) async throws -> Outcome {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forReadingFrom: source) else { throw Failure.unreadable(source.path) }
        defer { try? handle.close() }
        var writer = ChunkWriter(folder: folder, size: chunkCharacters)
        var buffer = Data()
        var read = 0
        var lines = 0
        while read < limit {
            if stop() { throw Failure.stopped }
            guard let data = try handle.read(upToCount: min(max(readSize, 1), limit - read)), !data.isEmpty else { break }
            read += data.count
            buffer.append(data)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                if newline > start {
                    lines += 1
                    if let entry = entry(Data(buffer[start..<newline])) { try writer.add(entry) }
                }
                start = buffer.index(after: newline)
            }
            // What follows the last newline waits for the bytes that end it.
            buffer = Data(buffer[start...])
        }
        try writer.finish()
        return Outcome(chunks: writer.written, characters: writer.characters, lines: lines)
    }

    /// The kept text into chunk files: an entry goes into the chunk being
    /// filled unless it would take it past the size, when that chunk is
    /// written and a new one begun. One entry larger than a chunk is a
    /// chunk of its own.
    struct ChunkWriter {
        let folder: URL
        let size: Int
        private(set) var written = 0
        private(set) var characters = 0
        private var current = ""
        private var currentSize = 0

        init(folder: URL, size: Int) {
            self.folder = folder
            self.size = max(size, 1)
        }

        mutating func add(_ entry: String) throws {
            let length = entry.utf8.count + 1
            if currentSize > 0, currentSize + length > size { try flush() }
            current += entry
            current += "\n"
            currentSize += length
            characters += length
        }

        mutating func finish() throws {
            if currentSize > 0 { try flush() }
        }

        private mutating func flush() throws {
            written += 1
            try Data(current.utf8).write(to: folder.appendingPathComponent(SuperCompactFilter.chunkName(written), isDirectory: false),
                                         options: .atomic)
            current = ""
            currentSize = 0
        }
    }
}
