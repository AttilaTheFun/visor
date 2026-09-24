// A session file as it grows. Claude Code appends a record at a time; the
// watcher reads from where it left off, keeps a partial last line for the
// next read, and hands over whole lines. It listens for writes through
// the kernel where the file exists, and polls besides — for a file that
// does not exist yet, and for a write the kernel did not mention.

import Foundation

public final class ClaudeSessionWatcher: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private let onLines: ([ClaudeLine]) -> Void
    private var offset: UInt64
    private var partial = Data()
    /// Where the lines handed over so far end: the byte after the last
    /// whole line read. What a reader that keeps its place writes down.
    public private(set) var position: UInt64
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    /// - Parameter offset: where to start reading; the file's current size
    ///   to follow from here on, 0 to read everything first.
    public init(url: URL, startingAt offset: UInt64 = 0, queue: DispatchQueue = DispatchQueue(label: "claude.transcript.watch"),
                onLines: @escaping ([ClaudeLine]) -> Void) {
        self.url = url
        self.offset = offset
        self.position = offset
        self.queue = queue
        self.onLines = onLines
    }

    public func start() {
        queue.async {
            self.attach()
            self.read()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.source == nil { self.attach() }
                self.read()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.source?.cancel()
            self.source = nil
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
        }
    }

    private func attach() {
        guard source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Rewritten or moved: attach again next time round.
                source.cancel()
                self.source = nil
                if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
                return
            }
            self.read()
        }
        source.resume()
        self.source = source
    }

    private func read() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else {
            // Truncated: start over.
            if size < offset { offset = 0; position = 0; partial.removeAll() }
            return
        }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return }
        offset = size
        var buffer = partial + data
        // Everything up to the last newline is whole; the rest waits.
        guard let last = buffer.lastIndex(of: 0x0A) else { partial = buffer; return }
        partial = Data(buffer[buffer.index(after: last)...])
        position = offset - UInt64(partial.count)
        buffer = Data(buffer[..<last])
        let lines = ClaudeTranscriptParser.lines(in: buffer)
        if !lines.isEmpty { onLines(lines) }
    }
}
