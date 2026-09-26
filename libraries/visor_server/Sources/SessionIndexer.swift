// A session's file into the cache, off the main thread: what the file
// holds that the cache does not yet, then each line as it is written.
// The conversation is the branch that holds the file's last line; lines
// under a prompt abandoned by a fork are kept in the tree but make no
// rows. The main actor is handed the window of rows to show, then the
// lines of the conversation as they come.

import ClaudeTranscript
import Foundation
import MessageCache
import os
import VisorProtocol

private let log = Logger(subsystem: "com.LoganShire.Visor", category: "index")

final class SessionIndexer: @unchecked Sendable {
    /// What a session looks like once the cache is up to date with its file.
    struct Loaded: Sendable {
        let rows: [TranscriptEntry]
        let more: Bool
        let prompts: [String]
        let abandoned: Set<String>
        let abandonedPrompts: Int
    }

    /// A line of the conversation as it was written, with the rows it
    /// produced or changed.
    struct Line: Sendable {
        let uuid: String?
        let isPrompt: Bool
        let record: ClaudeRecord?
        let rows: [TranscriptEntry]
    }

    let sessionID: String
    let url: URL
    private let store: MessageCache
    private let window: Int
    private let queue: DispatchQueue
    private var assembler = TranscriptAssembler()
    private var members = Set<String>()
    private var abandoned = Set<String>()
    private var state: SourceState
    private var watcher: ClaudeSessionWatcher?
    private var stopped = false
    /// The agent's log format, read into lines of Claude's shape.
    private let parser: AgentLogParser

    init(store: MessageCache, sessionID: String, url: URL, window: Int, parser: AgentLogParser = ClaudeLogParser()) {
        self.parser = parser
        self.store = store
        self.sessionID = sessionID
        self.url = url
        self.window = window
        queue = DispatchQueue(label: "visor.index." + sessionID.prefix(8), qos: .utility)
        state = SourceState(path: url.path, identity: "", bytes: 0, nextSeq: 0)
    }

    /// Catches the cache up with the file, hands over what to show, then
    /// follows the file. Both closures are called on the indexer's queue.
    func start(onLoaded: @escaping @Sendable (Loaded) -> Void, onLines: @escaping @Sendable ([Line]) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            catchUp()
            onLoaded(loaded())
            let parser = self.parser
            let watcher = ClaudeSessionWatcher(url: url, startingAt: state.bytes, queue: queue, parse: { parser.lines(in: $0) }) { [weak self] lines in
                guard let self, !self.stopped else { return }
                let taken = self.take(lines)
                if !taken.isEmpty { onLines(taken) }
            }
            watcher.start()
            self.watcher = watcher
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            watcher?.stop()
            watcher = nil
        }
    }

    // MARK: Catching up

    /// The file's identity now: which inode, how long.
    private func fileFacts() -> (inode: UInt64, size: UInt64) {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return ((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Reads what the file holds past where the cache stopped — all of
    /// it, for a file the cache has not seen, or one that is not the file
    /// it was — and writes it down.
    private func catchUp() {
        let facts = fileFacts()
        let identity = String(facts.inode)
        if let kept = store.sourceState(of: sessionID), kept.path == url.path, kept.identity == identity, kept.bytes <= facts.size {
            state = kept
            // Reading on from where the cache stopped: a log that is a list
            // links its next line to the last one kept.
            parser.resume(after: store.nodes(in: sessionID).last?.key)
        } else {
            state = SourceState(path: url.path, identity: identity, bytes: 0, nextSeq: 0)
            do { try store.resetSource(sessionID, state: state) } catch { log.error("reset \(self.sessionID, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
        guard facts.size > state.bytes, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.bytes)
        guard let data = try? handle.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        let whole = data[..<last]
        let lines = parser.lines(in: Data(whole))
        var lineRecords: [SourceNode] = []
        var rowRecords: [PlacedMessage] = []
        for line in lines {
            let seq = state.nextSeq
            state.nextSeq += 1
            lineRecords.append(SourceNode(seq: seq, key: line.uuid, parentKey: line.parentUuid, kind: line.type, isPrompt: line.isPrompt))
            guard let record = line.record else { continue }
            for row in assembler.rows(for: record) {
                rowRecords.append(PlacedMessage(message: row, seq: seq, sourceKey: line.uuid))
            }
        }
        state.bytes += UInt64(last + 1)
        let started = Date()
        do { try store.ingest(sessionID, nodes: lineRecords, messages: rowRecords, state: state) } catch { log.error("ingest \(self.sessionID, privacy: .public): \(String(describing: error), privacy: .public)") }
        log.info("caught up \(self.sessionID, privacy: .public): \(lineRecords.count) lines, \(rowRecords.count) rows, \(Int(Date().timeIntervalSince(started) * 1000)) ms writing")
    }

    /// The branch, from the tree the cache holds, and the rows to show.
    private func loaded() -> Loaded {
        let shape = ClaudeBranch.current(nodes: store.nodes(in: sessionID).map { ClaudeBranch.Node(uuid: $0.key, parentUuid: $0.parentKey, isPrompt: $0.isPrompt) })
        members = shape.members
        abandoned = shape.abandoned
        do { try store.removeMessages(in: sessionID, sourceKeys: shape.abandoned) } catch { log.error("drop \(self.sessionID, privacy: .public): \(String(describing: error), privacy: .public)") }
        let page = store.messages(in: sessionID, limit: window)
        return Loaded(rows: page.messages, more: page.more, prompts: shape.prompts, abandoned: shape.abandoned, abandonedPrompts: shape.abandonedPrompts)
    }

    // MARK: Following

    /// Lines as the file grows: written down, and those on the
    /// conversation handed over with their rows.
    private func take(_ lines: [ClaudeLine]) -> [Line] {
        var lineRecords: [SourceNode] = []
        var rowRecords: [PlacedMessage] = []
        var taken: [Line] = []
        for line in lines {
            let seq = state.nextSeq
            state.nextSeq += 1
            lineRecords.append(SourceNode(seq: seq, key: line.uuid, parentKey: line.parentUuid, kind: line.type, isPrompt: line.isPrompt))
            // Under a prompt abandoned by a fork: in the tree, not the
            // conversation. A parent never seen is a line missed, not a
            // fork, and the line is kept.
            if let parent = line.parentUuid, !members.contains(parent), abandoned.contains(parent) {
                if let uuid = line.uuid { abandoned.insert(uuid) }
                continue
            }
            if let uuid = line.uuid { members.insert(uuid) }
            var rows: [TranscriptEntry] = []
            if let record = line.record {
                rows = assembler.rows(for: record)
                for row in rows { rowRecords.append(PlacedMessage(message: row, seq: seq, sourceKey: line.uuid)) }
            }
            taken.append(Line(uuid: line.uuid, isPrompt: line.isPrompt, record: line.record, rows: rows))
        }
        state.bytes = watcher?.position ?? state.bytes
        do { try store.ingest(sessionID, nodes: lineRecords, messages: rowRecords, state: state) } catch { log.error("follow \(self.sessionID, privacy: .public): \(String(describing: error), privacy: .public)") }
        return taken
    }

    // MARK: Paging

    /// The rows before one, oldest first, and whether there are more.
    func earlier(before rowID: String, limit: Int, completion: @escaping @Sendable ([TranscriptEntry], Bool) -> Void) {
        queue.async { [self] in
            guard let position = store.seq(of: rowID, in: sessionID) else { return completion([], false) }
            let page = store.messages(in: sessionID, limit: limit, before: position)
            completion(page.messages, page.more)
        }
    }
}
