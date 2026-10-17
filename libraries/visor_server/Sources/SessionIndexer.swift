// A session's file into the cache, off the main actor: what the file
// holds that the cache does not yet, then each line as it is written.
// The conversation is the branch that holds the file's last line; lines
// under a prompt abandoned by a fork are kept in the tree but make no
// rows. Whoever listens is given the window of rows to show, then the
// lines of the conversation as they come, in order.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol


actor SessionIndexer {
    /// What a session looks like once the cache is up to date with its file.
    struct Loaded: Sendable {
        let rows: [TranscriptEntry]
        let more: Bool
        /// The row the first of `rows` follows ("" when it is the first of
        /// all; nil when not known).
        var follows: String? = nil
        let prompts: [String]
        let abandoned: Set<String>
        let abandonedPrompts: Int
        /// Where the conversation stands (the prompt its latest turn began
        /// with), and its newest message.
        let head: String?
        let leaf: String?
        /// The file's newest message is on another branch: that branch's
        /// latest prompt ("" when it has none), or nil.
        let elsewhere: String?
    }

    /// A line of the conversation as it was written, with the rows it
    /// produced or changed.
    struct Line: Sendable {
        let uuid: String?
        let isPrompt: Bool
        let isMessage: Bool
        let record: ClaudeRecord?
        let rows: [TranscriptEntry]
    }

    /// What the indexer says, in order: the session as it stands once the
    /// cache has caught up with the file, then what the file gains — the
    /// conversation's lines, and when the file's newest message comes to be
    /// on another branch (that branch's latest prompt) or back on this one
    /// (nil).
    enum Event: Sendable {
        case loaded(Loaded)
        case lines([Line])
        case elsewhere(String?)
    }

    let sessionID: String
    let url: URL
    private let store: MessageCache
    private let window: Int
    private var assembler = TranscriptAssembler()
    private var members = Set<String>()
    private var abandoned = Set<String>()
    private var state: SourceState
    /// The agent's log format, read into lines of Claude's shape.
    private let parser: any AgentLogParser
    /// Where the conversation stood when last read: its branch is kept to.
    private let head: String?
    /// Whether the newest message read so far is on another branch, and
    /// the newest prompt read on any branch, by uuid with its words.
    private var elsewhere = false
    private var newestPrompt: (uuid: String, text: String)?

    /// The cache's word for a file read whole by this build: an earlier one
    /// left the rows of lines it took for another branch unread, and a
    /// file it read is read again, once.
    static let reading = 2

    init(store: MessageCache, sessionID: String, url: URL, window: Int, format: AgentLog.Format = .claude, head: String? = nil) {
        self.head = head
        parser = format.parser()
        self.store = store
        self.sessionID = sessionID
        self.url = url
        self.window = window
        state = SourceState(path: url.path, identity: "", bytes: 0, nextSeq: 0)
    }

    /// Catches the cache up with the file, says what to show, then follows
    /// the file for as long as anyone listens.
    nonisolated func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let indexing = Task { await self.index(into: continuation) }
            continuation.onTermination = { _ in indexing.cancel() }
        }
    }

    private func index(into continuation: AsyncStream<Event>.Continuation) async {
        catchUp()
        continuation.yield(.loaded(loaded()))
        for await batch in FileTail.batches(of: url, startingAt: state.bytes, watching: ServerPlatform.current.files) {
            let was = otherBranch
            let taken = take(parser.lines(in: batch.data), endingAt: batch.position)
            if !taken.isEmpty { continuation.yield(.lines(taken)) }
            if otherBranch != was { continuation.yield(.elsewhere(otherBranch)) }
        }
        continuation.finish()
    }

    // MARK: Catching up

    /// The file's identity now: which inode, how long.
    private func fileFacts() -> (inode: UInt64, size: UInt64) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return ((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// How much of the file a catch-up reads and writes down at a time: a
    /// conversation runs to hundreds of megabytes, and what is read is
    /// kept as it goes, so a reading cut short carries on from there.
    static let piece = 16 << 20

    /// Reads what the file holds past where the cache stopped — all of
    /// it, for a file the cache has not seen, or one that is not the file
    /// it was — and writes it down, a piece at a time. The file is known by
    /// its inode, so a second name for it (a renamed folder's link) reads
    /// on from where the first left off.
    private func catchUp() {
        let facts = fileFacts()
        let identity = "\(facts.inode)/\(Self.reading)"
        if let kept = store.sourceState(of: sessionID), kept.identity == identity, kept.bytes <= facts.size {
            state = kept
            state.path = url.path
            // Reading on from where the cache stopped: a log that is a list
            // links its next line to the last one kept.
            parser.resume(after: store.nodes(in: sessionID).last?.key)
        } else {
            state = SourceState(path: url.path, identity: identity, bytes: 0, nextSeq: 0)
            do { try store.resetSource(sessionID, state: state) } catch { VisorServer.log("index: reset \(self.sessionID): \(String(describing: error))") }
        }
        guard facts.size > state.bytes, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.bytes)
        let started = Date()
        var lineCount = 0, rowCount = 0
        var carried = Data()
        while true {
            let piece = (try? handle.read(upToCount: Self.piece)) ?? Data()
            let data = carried + piece
            guard let last = data.lastIndex(of: 0x0A) else {
                if piece.isEmpty { break }
                carried = data
                continue
            }
            var lineRecords: [SourceNode] = []
            var rowRecords: [PlacedMessage] = []
            for line in parser.lines(in: Data(data[..<last])) {
                let seq = state.nextSeq
                state.nextSeq += 1
                lineRecords.append(SourceNode(seq: seq, key: line.uuid, parentKey: line.parentUuid, kind: line.type, isPrompt: line.isPrompt))
                note(prompt: line)
                guard let record = line.record else { continue }
                for row in assembler.rows(for: record) {
                    rowRecords.append(PlacedMessage(message: row, seq: seq, sourceKey: line.uuid))
                }
            }
            state.bytes += UInt64(last - data.startIndex + 1)
            do { try store.ingest(sessionID, nodes: lineRecords, messages: rowRecords, state: state) } catch {
                VisorServer.log("index: ingest \(self.sessionID): \(String(describing: error))")
            }
            lineCount += lineRecords.count
            rowCount += rowRecords.count
            carried = Data(data[(last + 1)...])
            if piece.isEmpty { break }
        }
        VisorServer.log("index: caught up \(self.sessionID): \(lineCount) lines, \(rowCount) rows, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// The branch, from the tree the cache holds, and the rows to show.
    private func loaded() -> Loaded {
        let nodes = store.nodes(in: sessionID).map { node in
            ClaudeBranch.Node(uuid: node.key, parentUuid: node.parentKey, isPrompt: node.isPrompt, isMessage: Self.isMessage(node.kind))
        }
        let shape = ClaudeBranch.current(nodes: nodes, head: head)
        members = shape.members
        abandoned = shape.abandoned
        elsewhere = shape.wentOnElsewhere
        // The other branch's latest prompt, by its row, before the rows of
        // abandoned branches go: an earlier reading may have read it.
        if elsewhere, let other = nodes.last(where: { $0.isPrompt && $0.uuid.map(shape.abandoned.contains) == true })?.uuid,
           newestPrompt?.uuid != other, let seq = store.seq(of: "user-file-" + other, in: sessionID),
           let row = store.messages(in: sessionID, limit: 1, before: seq + 1).messages.last {
            newestPrompt = (other, row.text)
        }
        do { try store.removeMessages(in: sessionID, sourceKeys: shape.abandoned) } catch { VisorServer.log("index: drop \(self.sessionID): \(String(describing: error))") }
        // One more than the window: the row before it, which a client
        // that keeps it carries its history on from.
        let page = store.messages(in: sessionID, limit: window + 1)
        let over = page.messages.count > window
        return Loaded(rows: Array(page.messages.suffix(window)), more: over || page.more,
                      follows: over ? page.messages.first?.id : (page.more ? nil : ""),
                      prompts: shape.prompts, abandoned: shape.abandoned, abandonedPrompts: shape.abandonedPrompts,
                      head: shape.head, leaf: shape.leaf, elsewhere: otherBranch)
    }

    /// The other branch's latest prompt while the file's newest message is
    /// on it ("" when it has none read), or nil.
    private var otherBranch: String? {
        guard elsewhere else { return nil }
        guard let newestPrompt, !members.contains(newestPrompt.uuid) else { return "" }
        return newestPrompt.text
    }

    /// Keeps the newest prompt read, on whichever branch.
    private func note(prompt line: ClaudeLine) {
        guard line.isPrompt, let uuid = line.uuid, case .user(let text, _)? = line.record?.kind else { return }
        newestPrompt = (uuid, text)
    }

    static func isMessage(_ kind: String) -> Bool { kind == "user" || kind == "assistant" }

    // MARK: Following

    /// Lines as the file grows: written down, and those on the
    /// conversation handed over with their rows.
    private func take(_ lines: [ClaudeLine], endingAt position: UInt64) -> [Line] {
        var lineRecords: [SourceNode] = []
        var rowRecords: [PlacedMessage] = []
        var taken: [Line] = []
        for line in lines {
            let seq = state.nextSeq
            state.nextSeq += 1
            lineRecords.append(SourceNode(seq: seq, key: line.uuid, parentKey: line.parentUuid, kind: line.type, isPrompt: line.isPrompt))
            note(prompt: line)
            // Under a prompt abandoned by a fork: in the tree, not the
            // conversation. A parent never seen is a line missed, not a
            // fork, and the line is kept.
            if let parent = line.parentUuid, !members.contains(parent), abandoned.contains(parent) {
                if let uuid = line.uuid { abandoned.insert(uuid) }
                if line.isMessage { elsewhere = true }
                continue
            }
            if let uuid = line.uuid { members.insert(uuid) }
            if line.isMessage { elsewhere = false }
            var rows: [TranscriptEntry] = []
            if let record = line.record {
                rows = assembler.rows(for: record)
                for row in rows { rowRecords.append(PlacedMessage(message: row, seq: seq, sourceKey: line.uuid)) }
            }
            taken.append(Line(uuid: line.uuid, isPrompt: line.isPrompt, isMessage: line.isMessage, record: line.record, rows: rows))
        }
        state.bytes = position
        do { try store.ingest(sessionID, nodes: lineRecords, messages: rowRecords, state: state) } catch { VisorServer.log("index: follow \(self.sessionID): \(String(describing: error))") }
        return taken
    }

    // MARK: Paging

    /// The rows before one, oldest first, and whether there are more.
    func earlier(before rowID: String, limit: Int) -> (rows: [TranscriptEntry], more: Bool) {
        guard let position = store.seq(of: rowID, in: sessionID) else { return ([], false) }
        let page = store.messages(in: sessionID, limit: limit, before: position)
        return (page.messages, page.more)
    }
}
