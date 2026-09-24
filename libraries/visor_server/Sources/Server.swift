// The WebSocket server: listens on every interface (the Tailscale one
// included), takes a password on each connection, then routes the
// protocol's envelopes to the sessions. Sessions live as long as the app;
// their transcripts are replayed to whoever subscribes.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

/// The server's message cache: every session's rows, from the agents' own
/// files where they have one and from their events where they do not.
/// Tests point `shared` at a cache of their own.
public enum ServerCache {
    nonisolated(unsafe) public static var shared: MessageCache = .open(named: "messages")
    private static let queue = DispatchQueue(label: "visor.cache", qos: .utility)

    /// Keeps a row an agent's event produced, after the rows before it.
    static func keep(_ entry: TranscriptEntry, in session: String) {
        queue.async { try? shared.append(session, [entry]) }
    }
}

/// One agent session on the host: its process, its transcript, who watches it.
@MainActor
public final class SessionRecord: ObservableObject {
    public private(set) var info: SessionInfo
    public private(set) var entries: [TranscriptEntry] = [] {
        didSet {
            revision += 1
            stamp(from: oldValue)
            onRevision?()
        }
    }
    /// Counts up with every change to the rows; what a client syncing
    /// over HTTP compares to.
    public private(set) var revision = 0
    /// Counts up when the rows were rebuilt as a whole — a row went, or
    /// the order changed — which a client cannot take as a delta.
    public private(set) var generation = 0
    /// The revision at which each row last changed, so a client is given
    /// only the rows past the revision it holds.
    private var rowSeq: [String: Int] = [:]

    /// After the rows changed: which rows are new or different since
    /// `old`, stamped with this revision; or, if any row went or moved,
    /// a new generation with every row stamped.
    private func stamp(from old: [TranscriptEntry]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = entries.map(\.id)
        let kept = newIDs.filter { oldByID[$0] != nil }
        let oldOrder = old.map(\.id).filter { id in newIDs.contains(id) }
        if kept.count != old.count || kept != oldOrder {
            generation += 1
            rowSeq = Dictionary(newIDs.map { ($0, revision) }, uniquingKeysWith: { a, _ in a })
            return
        }
        for row in entries where oldByID[row.id] != row { rowSeq[row.id] = revision }
    }

    /// The rows changed since a revision — every row, for one before the
    /// generation began.
    func rows(since: Int) -> [TranscriptEntry] {
        let served = entries.suffix(Self.servedRows)
        return served.filter { (rowSeq[$0.id] ?? revision) > since }
    }

    /// The turn's status lines so far — tool calls, subagents, shells,
    /// thinking — as announced, kept here so a client that subscribes
    /// mid-turn gets all of them. Cleared when the turn ends.
    private var turn = TurnStatus()
    var turnStatus: [StatusItem] { turn.items }
    /// The rows changed: whoever is waiting on a revision is answered.
    var onRevision: (() -> Void)?
    /// What is streaming, or has streamed and is not yet on the record:
    /// one entry per assistant message, in order, by message id. Each
    /// stays until a row with its id arrives from the file, so a message
    /// is never lost between the stream's end and the file's catching up.
    public private(set) var streams: [(id: String, text: String)] = []
    /// The words of every stream, for anything that still wants one string.
    public var streaming: String { streams.map(\.text).joined(separator: "\n\n") }
    public private(set) var activity: String?
    public private(set) var error: String?
    /// Not a `let`: a session whose folder moved is given a new agent,
    /// because the directory is fixed when the process spawns.
    private(set) var process: AgentProcess
    var subscribers: Set<ObjectIdentifier> = []
    /// The permission mode changed mid-turn: restart the process when the turn ends.
    var restartWhenIdle = false
    /// A turn was handed to the agent and never finished. Set when the
    /// message is sent, cleared when the agent goes idle, and persisted:
    /// after a kill it is the only sign that a reply is owed.
    var interrupted = false

    /// The agent's own session file, followed as it grows: the transcript
    /// of record for a Claude session. Rows announced by the process are
    /// only the ones the file does not carry.
    /// The file into the cache and to here, off the main thread.
    private var indexer: SessionIndexer?
    private var fileRetries = 0
    /// Whether the cache holds rows before the first one here.
    private var moreBefore = false
    /// How many times the file has been read in: what a test waits on.
    private(set) var fileLoads = 0

    /// Waits until the file has been read in once more than `count`.
    func waitForFile(past count: Int, timeout: TimeInterval = 5) async {
        let limit = Date().addingTimeInterval(timeout)
        while fileLoads <= count, Date() < limit { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    /// The lines of the file the conversation holds, by uuid: what a new
    /// line must follow to be part of it rather than of a branch beside it.
    /// The prompts shown, in order, on the branch the chat follows. When
    /// the file is read again and the last of them is on an abandoned
    /// branch, the session was forked elsewhere and the chat moved to
    /// the newer branch — which the user is told, since nothing else
    /// would say why messages went away.
    private(set) var shownPrompts: [String] = []
    /// What the user is told about the session until they acknowledge it.
    var notice: String?
    /// Rows the file produced, told to subscribers by the server.
    var onFileRows: (([TranscriptEntry]) -> Void)?
    /// The transcript was read again from the file and is different, or
    /// there is something new to tell: subscribers get the whole of it.
    var onFileReplaced: (() -> Void)?
    /// The session's summary changed (a new latest message): the list of
    /// sessions is sent again.
    var onInfoChanged: (() -> Void)?
    /// Busy inferred from the file, for a session the terminal holds.
    var onFileBusy: ((Bool) -> Void)?
    /// What the terminal drew, for the one client it is drawn for.
    var onTerminalBytes: ((Envelope) -> Void)?
    /// Whether the agent is drawing full-screen.
    private var altScreen = false
    /// What the terminal has shown, kept for whoever looks next.
    private(set) var scrollback = Data()
    static let scrollbackLimit = 200_000

    var terminal: TerminalCapable? { process as? TerminalCapable }
    func setMode(_ mode: SessionMode) { info.mode = mode }

    init(info: SessionInfo, process: AgentProcess, entries: [TranscriptEntry] = [], shownPrompts: [String] = [], notice: String? = nil) {
        self.info = info
        self.process = process
        self.entries = entries
        self.shownPrompts = shownPrompts
        self.notice = notice
    }

    /// Told to the user when the chat leaves a branch behind.
    static func forkNotice(lost: Int) -> String {
        let gone = lost == 1 ? "One message shown here" : "\(lost) messages shown here"
        return "Another Claude Code resumed this session and sent a newer message on a different branch: the session was forked. The chat now follows that newer branch. \(gone) before this was on the branch left behind and is no longer part of the conversation."
    }

    /// Reads the session's file into the transcript and follows it from
    /// there. Rows the server made itself for what the user said stay
    /// where they are; the file's copy of the same words is not a second
    /// row. Called once the agent has a session id, and again after a
    /// restart (the watcher is replaced).
    func followFile() {
        guard info.agent == .claude, let id = process.resumeID else { return }
        indexer?.stop()
        indexer = nil
        guard let url = ClaudeSessionFiles.locate(sessionID: id, cwd: info.cwd) else {
            // Not written yet (the agent announces its id before its first
            // record): look again shortly, for as long as a first turn
            // could take.
            guard fileRetries < 240 else { return }
            fileRetries += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.indexer == nil, self.process.resumeID == id else { return }
                self.followFile()
            }
            return
        }
        fileRetries = 0
        // The cache catches up with the file off the main thread and hands
        // over the window to show; then each line as the agent writes it.
        let indexer = SessionIndexer(store: ServerCache.shared, sessionID: info.id, url: url, window: Self.servedRows)
        indexer.start(onLoaded: { [weak self] loaded in
            Task { @MainActor in self?.apply(loaded: loaded) }
        }, onLines: { [weak self] lines in
            Task { @MainActor in self?.apply(lines: lines) }
        })
        self.indexer = indexer
    }

    /// The file as read: the conversation is the branch that holds its
    /// last line — what an agent resuming now would continue. If the last
    /// prompt this chat showed is on a branch beside it, the session was
    /// forked elsewhere and moved on; the chat follows, and says so.
    private func apply(loaded: SessionIndexer.Loaded) {
        if let last = shownPrompts.last, loaded.abandoned.contains(last) {
            notice = Self.forkNotice(lost: shownPrompts.filter { loaded.abandoned.contains($0) }.count)
        }
        let told = notice != nil
        shownPrompts = Array(loaded.prompts.suffix(Self.rememberedPrompts))
        moreBefore = loaded.more
        let before = entries.map(\.id)
        if !loaded.rows.isEmpty { entries = merged(fileRows: loaded.rows, into: entries) }
        if told || entries.map(\.id) != before { onFileReplaced?() }
        // A session read from its file for the first time has no summary yet.
        if info.preview == nil { noteLatest(at: info.created) }
        fileLoads += 1
    }

    /// Lines of the conversation as the agent writes them.
    private func apply(lines: [SessionIndexer.Line]) {
        var changed: [TranscriptEntry] = []
        for line in lines {
            if line.isPrompt, !isOurs(prompt: line.record) {
                // A prompt this server did not send: another agent is on
                // the session. With no agent of ours running, the file as
                // it stands now is what the next one resumes — read it
                // again, which tells the user if that means a fork. With
                // ours mid-turn the row is shown like any other, and the
                // branch is worked out when the agent restarts.
                if process.processID == nil { followFile(); return }
            }
            if line.isPrompt, let uuid = line.uuid {
                shownPrompts.append(uuid)
                if shownPrompts.count > Self.rememberedPrompts * 2 { shownPrompts.removeFirst(Self.rememberedPrompts) }
            }
            for row in line.rows where take(fileRow: row) { changed.append(row) }
            // With the terminal holding the session there is no stream to
            // say whether the agent is working: the file says — a prompt
            // or a tool result opens work, a final answer ends it.
            if info.mode.isTUI, let record = line.record, let busy = Self.busy(after: record), busy != info.busy {
                info.busy = busy
                onFileBusy?(busy)
            }
        }
        if !changed.isEmpty { onFileRows?(changed) }
    }

    /// How many prompts are remembered as shown: enough to count what a
    /// fork left behind.
    static let rememberedPrompts = 200

    /// Whether a prompt in the file is one this server sent — the words of
    /// a row waiting to be settled — or one the agent fed itself (a
    /// command's expansion, a reminder). A terminal's prompts are all the
    /// user's own.
    private func isOurs(prompt record: ClaudeRecord?) -> Bool {
        if info.mode.isTUI { return true }
        guard case .user(let text, _)? = record?.kind else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") { return true }
        return entries.contains { $0.role == .user && $0.id.hasPrefix("user-") && !$0.id.hasPrefix("user-file-") && Self.sameWords(trimmed, $0.text) }
    }

    /// Where the last screen begins in these bytes: the start of the
    /// full-screen interface (\u{1B}[?1049h) or a full clear (\u{1B}[2J).
    static func lastRange(of text: String, in data: Data) -> Range<Data.Index>? {
        let marker = Data(text.utf8)
        var found: Range<Data.Index>?
        var search = data.startIndex
        while let range = data[search...].range(of: marker) {
            found = range
            search = range.upperBound
            if search >= data.endIndex { break }
        }
        return found
    }

    private static func screenBoundary(in data: Data) -> Data.Index? {
        var found: Data.Index?
        for marker in [Data("\u{1B}[?1049h".utf8), Data("\u{1B}[2J".utf8)] {
            var search = data.startIndex
            while let range = data[search...].range(of: marker) {
                found = max(found ?? range.lowerBound, range.lowerBound)
                search = range.upperBound
                if search >= data.endIndex { break }
            }
        }
        return found
    }

    private static func busy(after record: ClaudeRecord) -> Bool? {
        switch record.kind {
        case .user, .toolResult: true
        case .assistant(_, _, let stop, _, _): stop == "tool_use" ? true : (stop == nil ? nil : false)
        case .title: nil
        }
    }

    /// Follows the file the first time anyone looks at a resumed session.
    func followFileIfNeeded() {
        guard indexer == nil else { return }
        followFile()
    }

    /// Rows read from the file replace what was kept, except the rows the
    /// server made for words the file has not written yet (a turn in
    /// flight), which stay at the end.
    private func merged(fileRows: [TranscriptEntry], into kept: [TranscriptEntry]) -> [TranscriptEntry] {
        // Only the rows after the last one the file has: a turn in flight.
        // Anything the server made earlier that the file does not carry
        // was never sent, and is not history.
        let fileUserTexts = fileRows.filter { $0.role == .user }.map(\.text)
        var pending: [TranscriptEntry] = []
        for row in kept.reversed() {
            guard row.role == .user, row.id.hasPrefix("user-"), !row.id.hasPrefix("user-file-") else { break }
            if fileUserTexts.contains(where: { Self.sameWords($0, row.text) }) { break }
            pending.insert(row, at: 0)
        }
        return fileRows + pending
    }

    /// Whether the file's copy of a user message is the server's: the
    /// same words, or the same words followed by the attached pictures'
    /// paths the server added for the agent.
    private static func sameWords(_ fileText: String, _ rowText: String) -> Bool {
        // Both trimmed: the file keeps the prompt without the whitespace
        // around it, and a message typed on a phone often ends in a space.
        let file = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = rowText.trimmingCharacters(in: .whitespacesAndNewlines)
        return file == row || (!row.isEmpty && file.hasPrefix(row + "\n\nAttached image"))
            || (row.isEmpty && file.hasPrefix("Attached image"))
    }

    /// Puts one row from the file into the transcript; false when it is
    /// the file's copy of words the server already has a row for.
    private func take(fileRow row: TranscriptEntry) -> Bool {
        if row.role == .user,
           let index = entries.lastIndex(where: { $0.role == .user && $0.id.hasPrefix("user-") && !$0.id.hasPrefix("user-file-") && Self.sameWords(row.text, $0.text) }) {
            // The same words, now on the record: keep the row, take the id.
            var settled = entries[index]
            settled.id = row.id
            settled.images = row.images.isEmpty ? settled.images : row.images
            settled.imageSizes = row.imageSizes.isEmpty ? settled.imageSizes : row.imageSizes
            entries[index] = settled
            return false
        }
        if row.role == .assistant { dropStream(carriedBy: row.id) }
        if let index = entries.firstIndex(where: { $0.id == row.id }) { entries[index] = row } else { entries.insert(row, at: fileInsertionIndex) }
        noteLatest()
        return true
    }

    /// Where a row from the file goes: before the rows the server made
    /// for words the file has not written yet, which stay at the end. A
    /// reply's row reaches the file a beat after it streamed, and a message
    /// sent in that beat is still later than the reply.
    private var fileInsertionIndex: Int {
        var index = entries.endIndex
        while index > entries.startIndex, entries[index - 1].role == .user,
              entries[index - 1].id.hasPrefix("user-"), !entries[index - 1].id.hasPrefix("user-file-") { index -= 1 }
        return index
    }

    /// Keeps the session's summary — the start of its latest message and
    /// when it came — after the transcript changed at its end.
    private func noteLatest(at time: Double = Date().timeIntervalSince1970) {
        guard let preview = entries.reversed().lazy.compactMap(Self.preview(of:)).first else { return }
        guard preview != info.preview else { return }
        info.preview = preview
        info.updated = time
        onInfoChanged?()
    }

    /// Fills the summary at load, so a session lists its latest message
    /// without being opened first. From the end of the session's own file
    /// where there is one: the rows kept in the store can stop short of
    /// the file — the store is written when a turn ends, and the reply's
    /// row reaches it from the file a moment later — and a summary from
    /// them showed the user's question with the answer already on disk.
    /// The time is the file's, so the list sorts by real activity, not by
    /// when the folder was first used. Nothing is broadcast — this runs
    /// before anyone subscribes. A summary saved by an earlier run is
    /// replaced by the file's, which may have moved on since; it stands
    /// only where there is no file to read.
    func primePreview() {
        // The file where it is expected — a single stat, no directory
        // scan at startup: a session whose folder moved just sorts by when
        // it was created, from what was kept, until it is next opened.
        if info.agent == .claude, let id = process.resumeID {
            let url = ClaudeSessionFiles.expectedURL(sessionID: id, cwd: info.cwd)
            if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                let tail = TranscriptAssembler.rows(in: ClaudeTranscriptParser.tailRecords(contentsOf: url))
                if let preview = tail.reversed().lazy.compactMap(Self.preview(of:)).first {
                    info.preview = preview
                    info.updated = modified.timeIntervalSince1970
                    return
                }
            }
        }
        // No file: from what was kept, made afresh — the rule for a summary
        // may have changed since it was saved — at the time it had.
        let saved = info.preview
        info.preview = nil
        noteLatest(at: info.updated ?? info.created)
        if info.preview == nil { info.preview = saved }
    }

    /// What a row says, in a line or two: its words, else the pictures it
    /// carries. Only what was said, by either side — a tool call or its
    /// result is not a message, and a row of nothing but those is skipped
    /// for the last row that spoke.
    static func preview(of entry: TranscriptEntry) -> String? {
        guard entry.role == .user || entry.role == .assistant else { return nil }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server's own notes to the agent (a restart's nudge) are not
        // the conversation's latest word.
        if entry.role == .user, text.hasPrefix("[Visor]") { return nil }
        // Blank lines go: a paragraph break would be the second of the two
        // lines a list shows, and show nothing.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !lines.isEmpty { return String(lines.joined(separator: "\n").prefix(300)) }
        if !entry.images.isEmpty { return entry.images.count == 1 ? "Image" : "\(entry.images.count) images" }
        return nil
    }

    /// The on-disk copy of this session.
    var stored: StoredSession {
        // What waits to be sent lives here and on the socket, not on disk.
        var kept = info
        kept.queued = []
        return StoredSession(info: kept, entries: Array(entries.suffix(Self.servedRows)), resumeID: process.resumeID, shape: StoredSession.currentShape, interrupted: interrupted, agentPID: process.processID, shownPrompts: Array(shownPrompts.suffix(Self.rememberedPrompts)), notice: notice)
    }

    /// The session's resume command, refreshed from the process (the id is
    /// known only once a turn has started).
    func refreshResume() { info.resumeCommand = process.resumeCommand }

    func setArchived(_ archived: Bool) {
        info.archived = archived
        info.busy = false
        activity = nil
        streams = []
    }

    /// A row from the record carries the stream with the same message id
    /// (the row's id is the message id, or the message id with a segment
    /// suffix): the stream has served and goes.
    private func dropStream(carriedBy rowID: String) {
        let base = rowID.split(separator: "#").first.map(String.init) ?? rowID
        streams.removeAll { $0.id == base }
    }

    var busy: Bool { info.busy }

    /// Whether the record carries a message: a row with its id, or that
    /// id with a segment suffix.
    func carries(messageID id: String) -> Bool {
        entries.contains { $0.role == .assistant && ($0.id == id || $0.id.hasPrefix(id + "#")) }
    }

    /// Applies an agent event to the transcript and returns the envelope
    /// that tells a subscriber the same thing — or nothing, for an event
    /// the record has overtaken.
    func apply(_ event: AgentEvent) -> Envelope? {
        switch event {
        case .delta(let id, let text):
            // A message already on the record is finished: its row can
            // reach the record before the last of its streamed words are
            // applied here, and words taken after it would only stand as
            // a stream nothing ever settles.
            guard !carries(messageID: id) else { return nil }
            if let last = streams.indices.last, streams[last].id == id { streams[last].text += text }
            else { streams.append((id: id, text: text)) }
            return .delta(session: info.id, message: id, text: text)
        case .entry(let entry):
            if entry.role == .assistant { dropStream(carriedBy: entry.id) }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
            noteLatest()
            ServerCache.keep(entry, in: info.id)
            return .entry(session: info.id, entry)
        case .activity(let label):
            activity = label
            return .activity(session: info.id, label)
        case .thinking(let on):
            turn.thinking(on)
            return .status(session: info.id, items: turn.items)
        case .toolStarted(let id, let name, let label, let tasks):
            turn.started(id: id, name: name, label: label, tasks: tasks)
            return .status(session: info.id, items: turn.items)
        case .toolFinished(let id):
            turn.finished(id: id)
            return .status(session: info.id, items: turn.items)
        case .busy(let value):
            info.busy = value
            if !value {
                info.pendingApproval = nil
                turn.clear()
                // A stream is not cleared by the turn ending: it stays
                // until the record carries its row. Only an agent whose
                // rows never come from a file lets the turn's end clear it.
                if info.agent != .claude || indexer == nil { streams = [] }
                // What the record carries by now has served.
                streams.removeAll { carries(messageID: $0.id) }
            }
            return .busy(session: info.id, value)
        case .failure(let message):
            error = message
            return .failure(session: info.id, message)
        case .context(let used, let limit):
            info.contextUsed = used
            if let limit { info.contextLimit = limit }
            // The sessions list carries it; the caller broadcasts that.
            return .sessions([])
        case .session:
            refreshResume()
            followFile()
            return .sessions([])
        case .tty(let data):
            // A window that attaches later is given these bytes to build
            // the screen from, so they must begin where a screen begins.
            // A full clear, or the start of the full-screen interface,
            // supersedes everything drawn before it — which both bounds
            // what is kept and keeps a replay from starting mid-sequence.
            if let last = Self.lastRange(of: "\u{1B}[?1049h", in: data) {
                altScreen = Self.lastRange(of: "\u{1B}[?1049l", in: data).map { $0.lowerBound < last.lowerBound } ?? true
            } else if Self.lastRange(of: "\u{1B}[?1049l", in: data) != nil {
                altScreen = false
            }
            if let boundary = Self.screenBoundary(in: data) {
                var kept = Data(data.suffix(from: boundary))
                // A screen that began with a clear is still the full-screen
                // one: the window is told so, or it would build it on the
                // ordinary screen and restore a page that never existed.
                let enter = Data("\u{1B}[?1049h".utf8)
                if altScreen, !kept.starts(with: enter) { kept = enter + kept }
                scrollback = kept
            } else {
                scrollback.append(data)
                if scrollback.count > Self.scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
                }
            }
            // Not broadcast: the terminal belongs to one window.
            onTerminalBytes?(.tty(session: info.id, data: data.base64EncodedString()))
            return .sessions([])
        }
    }

    func appendUser(_ text: String, images: [String] = []) -> Envelope {
        let entry = TranscriptEntry(id: "user-\(entries.count)-\(UUID().uuidString.prefix(6))", role: .user,
                                    text: text, images: images, imageSizes: AgentImages.pixelSizes(paths: images))
        entries.append(entry)
        error = nil
        noteLatest()
        // An agent with a file writes the user's words there, and the
        // cache takes them from it; any other agent's are kept from here.
        if info.agent != .claude { ServerCache.keep(entry, in: info.id) }
        return .entry(session: info.id, entry)
    }


    func markEnded() { info.ended = true; info.busy = false }

    /// Holds what the user said during a turn.
    func enqueue(_ text: String) { info.queued.append(text) }

    /// Takes the queue, leaving it empty.
    func takeQueue() -> [String] {
        let waiting = info.queued
        info.queued = []
        return waiting
    }

    /// Drops one queued message, or all of them.
    func unqueue(_ text: String?) {
        guard let text else { info.queued = []; return }
        if let index = info.queued.firstIndex(of: text) { info.queued.remove(at: index) }
    }

    /// The folder the session runs in, after the project moved.
    func setCWD(_ cwd: String) { info.cwd = cwd }

    /// Swaps in an agent built for the new folder; the transcript stays.
    func replaceProcess(_ replacement: AgentProcess) {
        process.onEvent = nil
        process.onModel = nil
        process = replacement
    }

    func setPermissions(skip: Bool) { info.skipPermissions = skip; process.skipPermissions = skip }

    /// The agent shim's connection waiting for the answer, by request id.
    var approvalWaiters: [String: ClientConnection] = [:]

    func setPendingApproval(_ request: ApprovalRequest?) { info.pendingApproval = request }

    func setReportedModel(_ model: String) { info.reportedModel = model }

    func setTitle(_ title: String) { info.title = title }

    func setSettings(model: String?, effort: String?) {
        info.model = model
        info.effort = effort
        process.model = model
        process.effort = effort
    }

    /// How much of a transcript is sent and kept. The session file holds
    /// the rest; a long thread is read from the end.
    static let servedRows = 600

    var transcriptEnvelope: Envelope { transcriptEnvelope(since: nil) }

    /// The record, or the rows of it changed since a revision the client
    /// holds — with the generation, so the client knows whether it may
    /// merge these as a delta or must take them as the whole.
    func transcriptEnvelope(since: Int?) -> Envelope {
        let rows = since.map { rows(since: $0) } ?? Array(entries.suffix(Self.servedRows))
        var e = Envelope.transcript(session: info.id, entries: rows, streaming: streaming,
                                    activity: activity, busy: info.busy, error: error)
        e.more = moreBefore || entries.count > Self.servedRows
        e.notice = notice
        e.revision = revision
        e.generation = generation
        return e
    }

    /// Everything that is not the record, in one piece.
    var ephemeralEnvelope: Envelope {
        .ephemeral(session: info.id, streams: streams.filter { !carries(messageID: $0.id) }.map { StreamChunk(id: $0.id, text: $0.text) }, status: turnStatus,
                   activity: activity, busy: info.busy, approval: info.pendingApproval, queued: info.queued, notice: notice)
    }

    /// The rows before one the client has, oldest of them first; `more`
    /// says whether there are rows before those too.
    func earlier(before id: String, completion: @escaping @Sendable (Envelope) -> Void) {
        var e = Envelope(type: "earlier")
        e.session = info.id
        // From what is here first; the cache holds what is before that.
        if let index = entries.firstIndex(where: { $0.id == id }), index > 0 {
            let start = max(0, index - Self.servedRows)
            e.entries = Array(entries[start..<index])
            e.more = start > 0 || moreBefore
            return completion(e)
        }
        guard let indexer, let first = entries.first?.id else { e.entries = []; e.more = false; return completion(e) }
        let base = e
        indexer.earlier(before: first, limit: Self.servedRows) { rows, more in
            var reply = base
            reply.entries = rows
            reply.more = more
            completion(reply)
        }
    }
}

/// What the menu bar app keeps of a session on disk — every session, live
/// or archived, so a relaunch of the app loses nothing: each comes back
/// idle and resumes its agent's own session on the next message.
struct StoredSession: Codable {
    var info: SessionInfo
    var entries: [TranscriptEntry]
    var resumeID: String?
    /// The transcript's shape; older files (nil) grouped a turn's tool calls
    /// after its text and are rebuilt from the agent's own store on load.
    var shape: Int?
    /// The session was mid-turn when the app went away.
    var interrupted: Bool?
    /// The agent's pid at the time of writing, so a later launch can find
    /// one of ours that outlived us.
    var agentPID: Int32?
    /// The prompts the chat had shown, by the agent's own uuids: how a
    /// later reading of the session file tells a fork from progress.
    var shownPrompts: [String]?
    /// A notice the user has not yet acknowledged.
    var notice: String?
    static let currentShape = 2

    init(info: SessionInfo, entries: [TranscriptEntry], resumeID: String?, shape: Int?,
         interrupted: Bool? = nil, agentPID: Int32? = nil, shownPrompts: [String]? = nil, notice: String? = nil) {
        self.info = info
        self.entries = entries
        self.resumeID = resumeID
        self.shape = shape
        self.interrupted = interrupted
        self.agentPID = agentPID
        self.shownPrompts = shownPrompts
        self.notice = notice
    }

    /// Every field but the session itself is optional, so a file written
    /// by a build with fewer of them still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decode(SessionInfo.self, forKey: .info)
        entries = try c.decodeIfPresent([TranscriptEntry].self, forKey: .entries) ?? []
        resumeID = try c.decodeIfPresent(String.self, forKey: .resumeID)
        shape = try c.decodeIfPresent(Int.self, forKey: .shape)
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted)
        agentPID = try c.decodeIfPresent(Int32.self, forKey: .agentPID)
        shownPrompts = try c.decodeIfPresent([String].self, forKey: .shownPrompts)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
    }
}

@MainActor
public final class VisorServer: ObservableObject {
    /// The one server of the menu bar app.
    public static let shared = VisorServer()

    @Published public private(set) var sessions: [SessionRecord] = []
    @Published public private(set) var clientCount = 0
    @Published public private(set) var listening = false
    @Published public private(set) var lastError: String?
    /// Required: the server does not listen without one. The user's own
    /// devices on the network are let in by the road's identity instead
    /// (Tailscale names the caller); the password is for a client the
    /// road does not vouch for — another user's device on a shared
    /// network, or a tool on this Mac.
    @Published public var password: String {
        didSet {
            UserDefaults.standard.set(password, forKey: "visor.password")
            if listener == nil, !password.isEmpty { start() }
        }
    }
    /// The network user this Mac belongs to, as the exposure reports it;
    /// requests the road names as theirs need no password.
    @Published public private(set) var hostLogin: String?
    /// What went wrong putting the front in place, or nil.
    @Published public private(set) var serveError: String?
    private var claudeModelsTimer: Timer?
    /// Tokens handed out by `hello` to clients the road (or the password)
    /// let in, for the socket's login; new each launch.
    private var tokens: [String] = []
    public let port: UInt16

    private var listener: NWListener?
    private var http: HTTPServer?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    /// The REST side, beside the WebSocket: `port + 1`.
    public var apiPort: UInt16 { port + 1 }
    /// What the permission shim presents instead of the password; new per launch.
    private let agentToken = UUID().uuidString
    /// Sessions this launch was asked to bring back into a running state:
    /// they were mid-turn when the app went away, and were named on the
    /// command line (or in VISOR_RESUME). Nudged once the listener is up.
    private var pendingResumes: [String] = []

    public init(port: UInt16 = Envelope.defaultPort) {
        self.port = port
        password = UserDefaults.standard.string(forKey: "visor.password") ?? ""
        loadSessions()
    }

    // MARK: Exposure

    /// How clients reach this server; Tailscale unless a fork says otherwise.
    public var exposure: any ServerExposure = TailscaleExposure()

    /// Whether a request may be answered: the road names the caller as
    /// this Mac's own user, or the bearer is the password or a token
    /// `hello` issued.
    func authorized(_ request: HTTPRequest) -> Bool {
        if let login = exposure.requester(headers: request.headers), let mine = hostLogin, login == mine { return true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        return bearer == password || tokens.contains(bearer)
    }

    /// A token for the socket's login, for a client that `hello` let in.
    private func issueToken() -> String {
        let token = UUID().uuidString.lowercased()
        tokens.append(token)
        if tokens.count > 512 { tokens.removeFirst(tokens.count - 512) }
        return token
    }

    /// The connection code a client takes to add this computer in one
    /// step: its name, its address, the password. Nil until the address
    /// is known and a password is set.
    public var connectionCode: ConnectionCode? {
        guard !password.isEmpty, let address = exposure.address() else { return nil }
        return ConnectionCode(name: hostName, host: address, password: password)
    }

    // MARK: Persistence

    /// ~/Library/Application Support/Visor/sessions.json (archive.json
    /// before sessions were all kept; read once and folded in).
    /// Tests point this at a scratch folder: a server built over the real
    /// archive ends the agents it records as orphans of a previous life.
    static var storeRoot: URL?
    private static var storeURL: URL {
        let base = storeRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.json")
    }

    /// Which sessions this launch carries on with. Whatever was running
    /// when the app went away comes back running — that is the default and
    /// needs no argument. The launch list only narrows it:
    ///     open -a "Visor Menu Bar" --args --resume-sessions <id>,<id>
    ///     VISOR_RESUME=none "…/Visor Menu Bar.app/Contents/MacOS/visor_menubar"
    /// ("all" is the default; "none" brings everything back idle instead.)
    static func requestedResumes() -> Set<String> {
        var raw = ProcessInfo.processInfo.environment["VISOR_RESUME"] ?? ""
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--resume-sessions"), arguments.index(after: flag) < arguments.endIndex {
            raw += "," + arguments[arguments.index(after: flag)]
        }
        let asked = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return asked.isEmpty ? ["all"] : asked
    }

    /// What a session is told when its turn was cut off by a restart. It
    /// arrives as a user turn, which is what it is: the agent's own process
    /// is gone, and only a new turn can start it again.
    static let resumeNudge = """
        [Visor] The Visor server restarted while you were working, so that turn was cut short \
        and whatever you were part-way through did not finish. Pick it up from where you left \
        off, checking the state of anything you had started before you carry on.
        """

    private func loadSessions() {
        var stored: [StoredSession] = []
        let legacy = Self.storeURL.deletingLastPathComponent().appendingPathComponent("archive.json")
        for url in [Self.storeURL, legacy] {
            guard let data = try? Data(contentsOf: url), data.count > 2 else { continue }
            do {
                var items = try JSONDecoder().decode([StoredSession].self, from: data)
                // Rows written before sizes were kept: read the sizes once
                // now, so an old thread lays out as steadily as a new one.
                for i in items.indices {
                    for j in items[i].entries.indices where items[i].entries[j].images.count > items[i].entries[j].imageSizes.count {
                        items[i].entries[j].imageSizes = AgentImages.pixelSizes(paths: items[i].entries[j].images)
                    }
                }
                stored += items.filter { item in !stored.contains { $0.info.id == item.info.id } }
            } catch {
                // A file we cannot read is not an empty one. Keep it, keep
                // quiet about nothing, and refuse to write over it: this is
                // the whole record of every session, and a decoding change
                // once turned it into "[]".
                let kept = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".unreadable")
                try? FileManager.default.removeItem(at: kept)
                try? FileManager.default.copyItem(at: url, to: kept)
                storeIsReadable = false
                lastError = "Could not read \(url.lastPathComponent): \(error). A copy is at \(kept.path); sessions are not being saved."
                return
            }
        }
        let asked = Self.requestedResumes()
        for item in stored {
            var info = item.info
            info.busy = false
            info.ended = false
            // A terminal is drawn for a client that is no longer here.
            info.mode = .chat
            // An agent of ours that outlived the app (we were killed
            // outright, or quit before it went): it still holds the
            // session, so it goes before anything resumes into it.
            if let pid = item.agentPID { Self.killOrphan(pid: pid, resume: item.resumeID) }
            // Running when we went away, so running again now.
            if item.interrupted == true, !asked.contains("none"), asked.contains(info.id) || asked.contains("all") {
                pendingResumes.append(info.id)
            }
            var entries = item.entries
            if item.shape != StoredSession.currentShape, let resume = item.resumeID {
                let rebuilt = backends.backend(for: info.agent)?.transcript(id: resume, cwd: info.cwd, limit: 300) ?? []
                if !rebuilt.isEmpty { entries = rebuilt }
            }
            let record = SessionRecord(info: info, process: makeProcess(info, resume: item.resumeID), entries: entries,
                                       shownPrompts: item.shownPrompts ?? [], notice: item.notice)
            record.process.seed(history: entries)
            record.refreshResume()
            record.interrupted = item.interrupted ?? false
            record.primePreview()
            sessions.append(record)
        }
        try? FileManager.default.removeItem(at: legacy)
        if !stored.isEmpty { saveArchive() }
    }

    /// Writes every session (the name is historical: it began as the archive).
    /// Ends an agent left over from a previous life of the app. The pid
    /// alone is not trusted — pids are reused — so the process must still
    /// look like the agent it claims to be.
    static func killOrphan(pid: Int32, resume: String?) {
        guard pid > 1, kill(pid, 0) == 0 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        let command = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard command.contains("claude") || command.contains("codex") || command.contains("openrouter") else { return }
        if let resume, !resume.isEmpty, !command.contains(resume) { return }
        kill(pid, SIGTERM)
        let limit = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < limit { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// False once a store failed to decode: nothing is written until the
    /// app is restarted against a file it understands.
    private var storeIsReadable = true

    private func saveArchive() {
        guard storeIsReadable else { return }
        let stored = sessions.map(\.stored)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        // Yesterday's file is kept beside today's. It costs nothing and it
        // is the difference between a bad write and a lost afternoon.
        let backup = Self.storeURL.deletingLastPathComponent().appendingPathComponent("sessions.previous.json")
        if let existing = try? Data(contentsOf: Self.storeURL), existing.count > 2, existing != data {
            try? existing.write(to: backup, options: .atomic)
        }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    func makeProcess(_ info: SessionInfo, resume: String?) -> AgentProcess {
        // The one backend for this agent makes and manages its process;
        // the server never branches on the agent itself.
        let backend = backends.backend(for: info.agent) ?? ClaudeBackend(kind: info.agent, tool: "claude", models: [])
        // The folder may have been renamed since this conversation began.
        // Put its history where the folder looks now, so both the agent
        // and a terminal can resume it from there.
        if let resume { backend.adoptHistory(id: resume, cwd: info.cwd) }
        let process: AgentProcess
        if case .tui(_, let cols, let rows) = info.mode,
           let terminal = backend.makeTerminal(cwd: info.cwd, skipPermissions: info.skipPermissions, resume: resume) {
            // Born at the window it is drawn for, so its first paint is
            // already the right shape.
            terminal.resize(cols: cols, rows: rows)
            process = terminal
        } else {
            // Chat.
            process = backend.makeProcess(cwd: info.cwd, skipPermissions: info.skipPermissions, resume: resume)
        }
        process.model = info.model
        process.effort = info.effort
        process.approvalEnvironment = ["VISOR_PORT": String(port), "VISOR_TOKEN": agentToken, "VISOR_SESSION": info.id]
        return process
    }

    /// The agents the server serves; a host assigns its own before start.
    public var backends: AgentBackends = .standard

    // MARK: Models

    /// Each provider's models: Claude's aliases and effort levels; Codex's
    /// from its models cache (~/.codex/models_cache.json, the listed ones)
    /// with the default from ~/.codex/config.toml.
    func catalogs() -> [AgentCatalog] { backends.all.map { $0.catalog() } }


    /// Points every session that ran in `from` at `to`. The agent holds
    /// its directory from the moment it spawns, so the process is rebuilt
    /// (resumed by its own id) — at once when idle, after the turn if not.
    @discardableResult
    func relocate(from: String, to: String) -> [SessionRecord] {
        let resolvedFrom = HostFolders.resolve(from)
        let moved = sessions.filter { HostFolders.resolve($0.info.cwd) == resolvedFrom }
        for record in moved {
            record.setCWD(to)
            guard !record.info.archived else { continue }
            if record.info.busy {
                record.restartWhenIdle = true
            } else {
                record.process.stop()
                record.replaceProcess(makeProcess(record.info, resume: record.process.resumeID))
                record.process.seed(history: record.entries)
            }
        }
        if !moved.isEmpty {
            saveArchive()
            broadcastSessions()
        }
        return moved
    }

    private func archive(_ record: SessionRecord) {
        record.process.stop()
        record.refreshResume()
        record.setArchived(true)
        record.restartWhenIdle = false
        // Archived means no process and nothing owed: it must not come back
        // running on the next launch.
        record.interrupted = false
        saveArchive()
        broadcast(record.transcriptEnvelope, session: record)
        broadcastSessions()
    }

    private func unarchive(_ record: SessionRecord) {
        record.setArchived(false)
        saveArchive()
        broadcastSessions()
    }

    /// Four short words, easy to type on a phone.
    public static func generatePassword() -> String {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heron", "iris", "jade", "kelp", "lumen", "maple", "north", "ocean", "pearl", "quill", "river", "stone", "tidal", "umber", "vale", "wren", "zephyr"]
        return (0..<4).map { _ in words.randomElement()! }.joined(separator: "-")
    }

    public var hostName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name
    }

    /// The host's Tailscale (100.64.0.0/10) and other IPv4 addresses.
    public static func addresses() -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                let name = String(cString: ifa.ifa_name)
                if address == "127.0.0.1" { continue }
                result.append((name, address))
            }
        }
        // Tailscale first: the CGNAT range on a utun interface.
        return result.sorted { a, b in a.1.hasPrefix("100.") && !b.1.hasPrefix("100.") }
    }

    /// Listens once there is a password; without one the menu says so
    /// and Settings is where to go. The listeners take loopback only:
    /// the front is the one way in from the network.
    public func start() {
        guard listener == nil, !password.isEmpty else { return }
        let http = HTTPServer(port: apiPort) { [weak self] request, respond in
            guard let self else { return respond(HTTPResponse(500, "{\"error\":\"gone\"}")) }
            self.route(request, respond: respond)
        }
        do { try http.start(); self.http = http } catch { lastError = "API: \(error)" }
        do {
            let params = NWParameters(tls: nil)
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.listening = true; self?.lastError = nil
                    case .failed(let error): self?.listening = false; self?.lastError = "\(error)"
                    case .cancelled: self?.listening = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "\(error)"
        }
        front()
        // Claude Code's models and default, asked of it now and every few
        // hours (a new model, a changed plan).
        // Codex's too, from its app-server.
        let refresh: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.broadcastCatalogs() } }
        ClaudeBackend.refreshModels(then: refresh)
        CodexBackend.refreshModels(then: refresh)
        claudeModelsTimer?.invalidate()
        claudeModelsTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            ClaudeBackend.refreshModels(then: refresh)
            CodexBackend.refreshModels(then: refresh)
        }
        // OpenRouter's model list, from the CLI, when it is a day old.
        OpenRouterBackend.refreshIfStale { [weak self] in
            Task { @MainActor in self?.broadcastCatalogs() }
        }
        resumePending()
    }

    /// The front on 443, put in place whenever it is not: there is no
    /// switch for it. What goes wrong is shown in the menu.
    public func front() {
        let exposure = self.exposure
        let port = self.port
        guard exposure.installed else { serveError = "\(exposure.title) is not installed"; return }
        Task.detached { [weak self] in
            var message: String?
            let identity = exposure.identity()
            await MainActor.run { [weak self] in self?.hostLogin = identity }
            if !exposure.fronts(port: port) {
                let output = exposure.front(port: port).lowercased()
                if output.contains("error") || output.contains("not enabled") || output.contains("not allowed") {
                    message = output.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? output
                }
            }
            await MainActor.run { [weak self] in self?.serveError = message }
        }
    }

    /// Carries on the turns that a restart interrupted. The agents are
    /// spawned by the send itself (resumed by their own id), so this is all
    /// it takes to bring a session back into a running state.
    private func resumePending() {
        let ids = pendingResumes
        pendingResumes = []
        for id in ids {
            guard let record = session(id), !record.info.archived else { continue }
            deliver(Self.resumeNudge, to: record)
        }
        if !ids.isEmpty { broadcastSessions() }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        http?.stop()
        http = nil
        // Whoever was waiting on a transcript gets what there is, now.
        for record in sessions { answerTranscriptWaiters(for: record) }
        for connection in connections.values { connection.close() }
        connections.removeAll()
        clientCount = 0
    }

    private func accept(_ nw: NWConnection) {
        let client = ClientConnection(connection: nw)
        let key = ObjectIdentifier(client)
        connections[key] = client
        clientCount = connections.count
        client.onMessage = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.handle(envelope, from: client)
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: key)
            self.clientCount = self.connections.count
            for session in self.sessions { session.subscribers.remove(key) }
        }
        client.start()
    }

    // MARK: REST

    /// The HTTP API: the same commands as the WebSocket, one request each,
    /// with the password as a bearer token. Paths may carry Tailscale
    /// Serve's `/api` mount prefix.
    ///   GET    /sessions                       the host, its sessions, the model catalogs
    ///   POST   /sessions                       start {id?, agent, cwd, title, skipPermissions}
    ///   POST   /sessions/{id}/send             {text}
    ///   POST   /sessions/{id}/stop|archive|unarchive
    ///   POST   /sessions/{id}/permissions      {skipPermissions}
    ///   POST   /sessions/{id}/settings         {model?, effort?}
    ///   POST   /sessions/{id}/approve          {id, allow}
    ///   DELETE /sessions/{id}
    /// Transcript syncing over HTTP: a client asks for the rows past the
    /// revision it has, and the answer waits — up to a while — until the
    /// rows change, so a client is never told nothing new when there is.
    /// The transcript is the record; the socket carries only what streams.
    private var transcriptWaiters: [String: [(revision: Int, respond: (HTTPResponse) -> Void)]] = [:]
    static let transcriptHold: TimeInterval = 25

    private func transcriptJSON(_ record: SessionRecord, since: Int?) -> HTTPResponse {
        .json(record.transcriptEnvelope(since: since).encoded())
    }

    /// Answers everyone waiting on this session's transcript with the
    /// rows changed since the revision each holds.
    private func answerTranscriptWaiters(for record: SessionRecord) {
        guard let waiting = transcriptWaiters.removeValue(forKey: record.info.id), !waiting.isEmpty else { return }
        for waiter in waiting { waiter.respond(transcriptJSON(record, since: waiter.revision)) }
    }

    func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let path = (request.path.split(separator: "?").first.map(String.init) ?? request.path).replacingOccurrences(of: "/api", with: "", options: .anchored)
        let parts = path.split(separator: "/").map(String.init)
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "transcript", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            record.followFileIfNeeded()
            if record.onRevision == nil { record.onRevision = { [weak self, weak record] in
                guard let self, let record else { return }
                self.answerTranscriptWaiters(for: record)
            } }
            let query = Self.query(request.path)
            let had = (query["since"] ?? query["revision"]).flatMap(Int.init)
            // Held only while the client has exactly what there is; a
            // client from before a restart, holding a higher number, is
            // answered at once with the whole (its generation will not
            // match, so it takes it as such).
            guard had == record.revision else { return respond(transcriptJSON(record, since: had.map { $0 > record.revision ? -1 : $0 })) }
            transcriptWaiters[record.info.id, default: []].append((revision: record.revision, respond: respond))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcriptHold) { [weak self, weak record] in
                guard let self, let record else { return }
                // Still waiting after the hold: answered with what there
                // is (nothing new), so the client asks again.
                self.answerTranscriptWaiters(for: record)
            }
            return
        }
        respond(route(request))
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        guard authorized(request) else { return HTTPResponse(401, "{\"error\":\"wrong password\"}") }
        var path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        if path.hasPrefix("/api") { path = String(path.dropFirst(4)) }
        let parts = path.split(separator: "/").map(String.init)
        let body = Envelope.decodeBody(request.body)
        func sessionsJSON() -> String {
            Envelope.welcome(host: hostName, sessions: sessions.map(\.info), catalogs: self.catalogs()).encoded()
        }
        let query = Self.query(request.path)
        switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "hello"):
            // The client is in (by the road's word or the password): its
            // name for this computer, whose it is, and a token to log
            // the socket in with.
            return .json(Envelope.hello(host: hostName, login: hostLogin ?? "", token: issueToken()).encoded())
        case ("GET", 1, "search"):
            // Rows whose words match, across every session: `q` is the
            // words, each required.
            let query = Self.query(request.path)["q"] ?? ""
            // The cache keys a session by the agent's own id; a hit names
            // the session as clients know it.
            let hits = ServerCache.shared.search(query).compactMap { hit -> [String: Any]? in
                guard let record = session(hit.session) else { return nil }
                return ["session": hit.session, "id": hit.messageID, "role": hit.role.rawValue,
                        "snippet": hit.snippet, "title": record.info.title, "cwd": record.info.cwd]
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["type": "search", "query": query, "hits": hits])) ?? Data("{}".utf8)
            return .json(String(decoding: data, as: UTF8.self))
        case ("GET", 1, "sessions"):
            return .json(sessionsJSON())
        case ("GET", 1, "folders"):
            var e = Envelope(type: "folders")
            e.path = HostFolders.resolve(query["path"] ?? "~")
            e.folders = HostFolders.list(query["path"] ?? "~")
            e.exists = HostFolders.exists(query["path"] ?? "~")
            return .json(e.encoded())
        case ("POST", 1, "folders"):
            guard let path = body.path, !path.isEmpty else { return HTTPResponse(400, "{\"error\":\"path required\"}") }
            guard HostFolders.make(path) else { return HTTPResponse(400, "{\"error\":\"could not create the folder\"}") }
            var e = Envelope(type: "folders")
            e.path = HostFolders.resolve(path)
            e.folders = HostFolders.list(path)
            return .json(e.encoded())
        case ("GET", 1, "resumable"):
            guard let agent = query["agent"].flatMap(AgentKind.init(wire:)) else { return HTTPResponse(400, "{\"error\":\"agent required\"}") }
            var e = Envelope(type: "resumable")
            e.resumable = backends.backend(for: agent)?.resumable(cwd: query["cwd"] ?? "") ?? []
            return .json(e.encoded())
        case ("GET", 1, "file"):
            // A picture the transcript named. Base64 in `text`, because
            // this side of the protocol speaks JSON and nothing else.
            guard let path = query["path"], !path.isEmpty else { return HTTPResponse(400, "{\"error\":\"path required\"}") }
            guard let data = AgentImages.read(path: path) else { return HTTPResponse(404, "{\"error\":\"no file there\"}") }
            var e = Envelope(type: "file")
            e.path = path
            e.text = data
            return .json(e.encoded())
        case ("POST", 1, "file"):
            // Something the user attached: base64 in `text`, a name in
            // `title`. It is written down and the path comes back, which
            // is what the agent is then told to look at.
            guard let data = body.text, !data.isEmpty else { return HTTPResponse(400, "{\"error\":\"text required\"}") }
            guard let path = AgentImages.save(base64: data, mediaType: nil, name: body.title) else {
                return HTTPResponse(400, Envelope.error("Those were not bytes we could write").encoded())
            }
            var e = Envelope(type: "file")
            e.path = path
            return .json(e.encoded())
        case ("POST", 1, "relocate"):
            // A project's folder was renamed or moved. `path` is where it
            // was, `cwd` where it is now; every session that ran there
            // follows it.
            guard let from = body.path, !from.isEmpty, let to = body.cwd, !to.isEmpty else {
                return HTTPResponse(400, "{\"error\":\"path and cwd required\"}")
            }
            guard HostFolders.exists(to) else { return HTTPResponse(400, Envelope.error("There is no folder at \(to)").encoded()) }
            let moved = relocate(from: from, to: to)
            var e = Envelope(type: "sessions")
            e.sessions = moved.map(\.info)
            return .json(e.encoded())
        case ("POST", 1, "restart"):
            // The one call an agent can make to replace the server it runs
            // under: `path` is the new bundle (omit it for a plain restart),
            // `session` the session to carry on besides the busy ones.
            var carry = sessions.filter(\.info.busy).map(\.info.id)
            if let named = body.session, !named.isEmpty, !carry.contains(named) { carry.append(named) }
            if let message = relaunch(installing: body.path, carrying: carry) {
                return HTTPResponse(400, Envelope.error(message).encoded())
            }
            var e = Envelope(type: "restart")
            e.sessions = sessions.filter { carry.contains($0.info.id) }.map(\.info)
            return .json(e.encoded())
        case ("POST", 1, "sessions"):
            guard let agent = body.agent else { return HTTPResponse(400, "{\"error\":\"agent required\"}") }
            var e = Envelope(type: "start")
            e.id = body.id; e.agent = agent; e.cwd = body.cwd; e.title = body.title; e.skipPermissions = body.skipPermissions; e.resume = body.resume
            e.mode = body.mode
            perform(e, from: nil)
            let created = session(e.id) ?? sessions.last
            return .json(created.map { Envelope.sessions([$0.info]).encoded() } ?? "{}")
        case ("DELETE", 2, "sessions"):
            var e = Envelope(type: "end"); e.session = parts[1]
            guard session(e.session) != nil else { return HTTPResponse(404, "{\"error\":\"no such session\"}") }
            perform(e, from: nil)
            return .json(sessionsJSON())
        case ("POST", 3, "sessions"):
            let action = parts[2]
            guard ["send", "stop", "unqueue", "archive", "unarchive", "permissions", "settings", "approve", "rename", "mode"].contains(action) else {
                return HTTPResponse(404, "{\"error\":\"unknown action\"}")
            }
            guard let record = session(parts[1]) else { return HTTPResponse(404, "{\"error\":\"no such session\"}") }
            var e = body
            e.type = action
            e.session = record.info.id
            perform(e, from: nil)
            return .json(Envelope.sessions([record.info]).encoded())
        default:
            return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    /// A request's query string, decoded.
    static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            out[key] = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
        }
        return out
    }

    private func handle(_ envelope: Envelope, from client: ClientConnection) {
        // The permission shim: one request per connection, answered later.
        if envelope.type == "approval_request" {
            guard envelope.token == agentToken, let record = session(envelope.session), let id = envelope.id else {
                client.send(.error("Not an agent of this host"))
                client.close(after: 0.2)
                return
            }
            let request = ApprovalRequest(id: id, tool: envelope.text ?? "tool", summary: envelope.prompt ?? "")
            record.approvalWaiters[id] = client
            record.setPendingApproval(request)
            broadcast(.approval(session: record.info.id, request), session: record)
            broadcastSessions()
            return
        }
        if !client.authenticated {
            guard envelope.type == "login" else { client.send(.error("Log in first")); return }
            let token = envelope.token ?? ""
            let byPassword = !password.isEmpty && (envelope.password ?? "") == password
            guard byPassword || (!token.isEmpty && tokens.contains(token)) else {
                client.send(.error("Wrong password"))
                client.close(after: 0.3)
                return
            }
            client.authenticated = true
            client.clientID = envelope.client ?? ""
            client.send(.welcome(host: hostName, sessions: sessions.map(\.info), catalogs: catalogs()))
            return
        }
        perform(envelope, from: client)
    }

    /// A command, from a WebSocket client or the REST side (no client).
    private func perform(_ envelope: Envelope, from client: ClientConnection?) {
        switch envelope.type {
        case "start":
            guard let agent = envelope.agent else { return }
            let id = envelope.id ?? UUID().uuidString
            let cwd = (envelope.cwd?.isEmpty == false ? envelope.cwd! : "~")
            let skip = envelope.skipPermissions ?? true
            let given = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Sessions live under their folder (the project), so the default
            // name is the agent's, numbered within the project.
            let resolvedCWD = HostFolders.resolve(cwd)
            let siblings = sessions.filter { HostFolders.resolve($0.info.cwd) == resolvedCWD && $0.info.agent == agent }.count
            let title = given.isEmpty ? "\(agent.title) \(siblings + 1)" : String(given.prefix(60))
            let resume = (envelope.resume ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let info = SessionInfo(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skip, created: Date().timeIntervalSince1970)
            // A resumed session shows what was said before it moved here.
            let past = resume.isEmpty ? [] : (backends.backend(for: agent)?.transcript(id: resume, cwd: cwd, limit: 300) ?? [])
            let record = SessionRecord(info: info, process: makeProcess(info, resume: resume.isEmpty ? nil : resume), entries: past)
            if !resume.isEmpty { record.refreshResume() }
            sessions.append(record)
            if let client { record.subscribers.insert(ObjectIdentifier(client)) }
            saveArchive()
            broadcastSessions()
        case "mode":
            // The other kind of process takes the session: this one ends
            // (once its turn does), the other resumes the same id.
            guard let record = session(envelope.session) else { return }
            let mode: SessionMode
            if envelope.mode == "tui" {
                // A terminal is drawn for one window: without a client and
                // its size there is nothing to draw for.
                let controller = client?.clientID ?? envelope.controller ?? ""
                guard !controller.isEmpty, let cols = envelope.cols, let rows = envelope.rows, cols > 0, rows > 0 else { return }
                mode = .tui(controller: controller, cols: cols, rows: rows)
            } else {
                mode = .chat
            }
            guard mode != record.info.mode else { return }
            // At once, as the confirmation said: a turn in flight is cut short.
            record.setMode(mode)
            restart(record)
            saveArchive()
            broadcastSessions()
        case "input":
            guard let record = session(envelope.session), record.info.mode.controlled(by: client?.clientID),
                  let data = envelope.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            record.terminal?.write(data)
        case "resize":
            // The controller's window changed: the terminal is re-drawn
            // for it, and the mode remembers the new shape.
            guard let record = session(envelope.session), record.info.mode.controlled(by: client?.clientID),
                  let controller = record.info.mode.controller,
                  let cols = envelope.cols, let rows = envelope.rows, cols > 0, rows > 0 else { return }
            guard record.info.mode.terminalSize.map({ $0 != (cols, rows) }) ?? true else { return }
            record.setMode(.tui(controller: controller, cols: cols, rows: rows))
            record.terminal?.resize(cols: cols, rows: rows)
            broadcastSessions()
        case "send":
            guard let record = session(envelope.session), let text = envelope.text else { return }
            // Writing to an archived session brings it back, same parameters.
            if record.info.archived { unarchive(record) }
            deliver(text, to: record, images: envelope.images ?? [])
        case "stop":
            guard let record = session(envelope.session) else { return }
            // The turn ends; the process stays. A terminal takes Escape, a
            // Claude chat a control message, and anything without its own
            // way to end a turn falls back to stopping (Codex spawns per
            // turn, so the next message starts a fresh one regardless).
            record.process.interrupt()
        case "unqueue":
            // No `text`: drop the lot. With one: drop that message.
            guard let record = session(envelope.session) else { return }
            record.unqueue(envelope.text)
            saveArchive()
            broadcastSessions()
        case "acknowledge":
            guard let record = session(envelope.session) else { return }
            record.notice = nil
            saveArchive()
        case "earlier":
            // Rows before the first one the client shows, from what is
            // here or from the cache.
            guard let client, let record = session(envelope.session), let before = envelope.before else { return }
            record.earlier(before: before) { reply in Task { @MainActor in client.send(reply) } }
        case "subscribe":
            guard let client, let record = session(envelope.session) else { return }
            record.subscribers.insert(ObjectIdentifier(client))
            // Bound before any turn: what the file says reaches subscribers
            // whether or not an agent of ours has run.
            if record.process.onEvent == nil { bind(record) }
            record.followFileIfNeeded()
            client.send(record.transcriptEnvelope)
            // Everything that is not the record, in one piece, so a window
            // that opens mid-turn misses none of it.
            client.send(record.ephemeralEnvelope)
            // What the terminal has shown goes to the one window it was
            // drawn for, and to no other — then the agent is asked to draw
            // it again, because a full-screen interface owns every cell and
            // its own painting is the only thing that is certainly true.
            if record.info.mode.controlled(by: client.clientID) {
                if !record.scrollback.isEmpty {
                    client.send(.tty(session: record.info.id, data: record.scrollback.base64EncodedString()))
                }
                record.terminal?.repaint()
            }
        case "permissions":
            guard let record = session(envelope.session), let skip = envelope.skipPermissions else { return }
            guard record.info.skipPermissions != skip else { return }
            record.setPermissions(skip: skip)
            // Claude's mode is a launch flag: the process restarts (resumed by
            // session id) once idle. Codex spawns per turn and just picks it up.
            if record.info.agent == .claude {
                if record.info.busy { record.restartWhenIdle = true } else { record.process.stop() }
            }
            broadcastSessions()
        case "approve":
            guard let record = session(envelope.session), let id = envelope.id, let allow = envelope.allow,
                  let waiter = record.approvalWaiters.removeValue(forKey: id) else { return }
            var answer = Envelope(type: "approval_result")
            answer.id = id
            answer.busy = allow
            waiter.send(answer)
            waiter.close(after: 0.5)
            if record.info.pendingApproval?.id == id { record.setPendingApproval(nil) }
            broadcast(.approval(session: record.info.id, record.info.pendingApproval), session: record)
            broadcastSessions()
        case "settings":
            guard let record = session(envelope.session) else { return }
            let model = envelope.model ?? record.info.model
            let effort = envelope.effort ?? record.info.effort
            guard model != record.info.model || effort != record.info.effort else { return }
            record.setSettings(model: model, effort: effort)
            saveArchive()
            // Claude's flags are launch flags: restart (resumed) once idle.
            if record.info.agent == .claude {
                if record.info.busy { record.restartWhenIdle = true } else { record.process.stop() }
            }
            broadcastSessions()
        case "rename":
            guard let record = session(envelope.session) else { return }
            let title = (envelope.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            record.setTitle(String(title.prefix(60)))
            saveArchive()
            broadcastSessions()
        case "archive":
            guard let record = session(envelope.session), !record.info.archived else { return }
            archive(record)
        case "unarchive":
            guard let record = session(envelope.session), record.info.archived else { return }
            unarchive(record)
        case "restart":
            // Quitting the app kills every agent, so an agent that wants a
            // new build of the server cannot install it itself: it dies
            // half-way. Here the server does it — a relauncher that outlives
            // us swaps the bundle and starts it again, naming the sessions
            // to carry on (this one included, by default).
            var carry = sessions.filter(\.info.busy).map(\.info.id)
            if let named = envelope.session, !carry.contains(named) { carry.append(named) }
            if let message = relaunch(installing: envelope.path, carrying: carry) {
                client?.send(.error(message))
            }
        case "end":
            guard let record = session(envelope.session) else { return }
            record.process.stop()
            record.markEnded()
            sessions.removeAll { $0 === record }
            saveArchive()
            broadcastSessions()
        default:
            client?.send(.error("Unknown message \(envelope.type)"))
        }
    }

    /// A session's default name: its directory's last component ("~" for home).
    static func directoryName(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        if trimmed == "~" || trimmed.isEmpty { return "Home" }
        return (trimmed as NSString).lastPathComponent
    }

    /// Ends the agent and makes a new one on the same session, which
    /// picks the conversation up as the file stands. A terminal starts at
    /// once; the chat's agent starts with the next message, which is when
    /// resuming matters. The transcript is read again, since the file may
    /// have moved on under another writer.
    private func restart(_ record: SessionRecord) {
        record.restartWhenIdle = false
        record.process.stop()
        record.process.stopAndWait(deadline: 3)
        record.replaceProcess(makeProcess(record.info, resume: record.process.resumeID))
        record.process.seed(history: record.entries)
        if record.info.mode.isTUI { launchTerminal(record) }
        record.followFile()
    }

    /// A terminal is live before anything is said: bound and started now.
    private func launchTerminal(_ record: SessionRecord) {
        if record.process.onEvent == nil { bind(record) }
        if let size = record.info.mode.terminalSize { record.terminal?.resize(cols: size.cols, rows: size.rows) }
        do { try record.terminal?.start() } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
        }
        saveArchive()
    }

    private func deliver(_ text: String, to record: SessionRecord, images: [String] = []) {
        // A turn in flight is left alone. What the user says now waits its
        // turn and goes over as soon as the agent falls idle — interrupting
        // is a deliberate act (`stop`), not the cost of typing.
        // A terminal at a prompt (trust this folder? accept bypass mode?
        // allow this tool?) is not at its input box: typed text would answer
        // the prompt with its default. The message waits until it is.
        if record.info.busy || (record.terminal.map { !$0.ready } ?? false) {
            record.enqueue(text)
            saveArchive()
            broadcastSessions()
            return
        }
        broadcast(record.appendUser(text, images: images), session: record)
        // Written down before the turn runs: if the app is killed while the
        // agent is working, the message the user sent is still here when it
        // comes back (the store is otherwise written at the end of a turn),
        // and `interrupted` says a reply is still owed.
        record.interrupted = true
        saveArchive()
        // The adapter's events reach subscribers through the record; bound
        // once, the first time the session takes a turn.
        if record.process.onEvent == nil { bind(record) }
        var forAgent = text
        if !images.isEmpty {
            let list = images.map { "- " + $0 }.joined(separator: "\n")
            let heading = images.count == 1 ? "Attached image:" : "Attached images:"
            forAgent = (text.isEmpty ? "" : text + "\n\n") + heading + "\n" + list
        }
        do {
            try record.process.send(forAgent)
            // The spawn happened inside `send`, so the pid is knowable
            // only now — and it is what finds this agent again if we are
            // killed outright.
            saveArchive()
        } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
            broadcast(record.apply(.busy(false)), session: record)
        }
    }

    private func bind(_ record: SessionRecord) {
        // The model Claude actually runs (its default, or the alias resolved).
        record.process.onModel = { [weak self, weak record] model in
            Task { @MainActor in
                // What actually ran, for display only. The user's choice
                // (info.model) is never changed here — a turn that fell
                // back to another model must not make that model stick.
                guard let self, let record, record.info.reportedModel != model else { return }
                record.setReportedModel(model)
                self.broadcastSessions()
            }
        }
        record.onTerminalBytes = { [weak self, weak record] envelope in
            guard let self, let record, let controller = record.info.mode.controller else { return }
            for key in record.subscribers where self.connections[key]?.clientID == controller {
                self.connections[key]?.send(envelope)
            }
        }
        record.onFileRows = { [weak self, weak record] rows in
            guard let self, let record else { return }
            for row in rows { self.broadcast(.entry(session: record.info.id, row), session: record) }
        }
        record.onFileReplaced = { [weak self, weak record] in
            guard let self, let record else { return }
            self.broadcast(record.transcriptEnvelope, session: record)
            self.saveArchive()
        }
        record.onInfoChanged = { [weak self] in self?.broadcastSessionsSoon() }
        record.onFileBusy = { [weak self, weak record] busy in
            guard let self, let record else { return }
            self.broadcast(.busy(session: record.info.id, busy), session: record)
            self.broadcastSessions()
        }
        record.process.onEvent = { [weak self, weak record] event in
            Task { @MainActor in
                guard let self, let record else { return }
                let out = record.apply(event)
                // The context and the session id land in the session list,
                // not an envelope.
                if case .context = event { self.broadcastSessions() }
                else if case .session = event { self.broadcastSessions() }
                // Terminal bytes went to the one window they are drawn for
                // inside apply; nothing goes to everyone — and certainly
                // not the empty list that stood in for "nothing", which
                // wiped every client's sessions with each chunk.
                else if case .tty = event {}
                else { self.broadcast(out, session: record) }
                // The turn's status lines, whole, whenever they change.
                if case .busy(false) = event { self.broadcast(.status(session: record.info.id, items: []), session: record) }
                if case .busy(let busy) = event {
                    if !busy, !record.approvalWaiters.isEmpty {
                        for waiter in record.approvalWaiters.values { waiter.close() }
                        record.approvalWaiters.removeAll()
                    }
                    // The agent's own id appears with the first turn; the
                    // transcript is written down whenever a turn ends.
                    record.refreshResume()
                    if !busy { record.interrupted = false; self.saveArchive() }
                    self.broadcastSessions()
                    if !busy, !record.info.queued.isEmpty, !record.restartWhenIdle {
                        // Everything said during the turn goes over as one
                        // turn, in the order it was said.
                        let waiting = record.takeQueue()
                        self.broadcastSessions()
                        self.deliver(waiting.joined(separator: "\n\n"), to: record)
                    }
                    if !busy, record.restartWhenIdle {
                        record.restartWhenIdle = false
                        record.process.stop()
                        // Rebuilt rather than merely stopped: a flag the
                        // agent takes at launch (its permission mode, its
                        // model) survives a restart of the same object, but
                        // its directory does not — that is fixed when the
                        // process is made.
                        record.replaceProcess(self.makeProcess(record.info, resume: record.process.resumeID))
                        if record.info.mode.isTUI { self.launchTerminal(record) }
                        if !record.info.queued.isEmpty {
                            let waiting = record.takeQueue()
                            self.broadcastSessions()
                            self.deliver(waiting.joined(separator: "\n\n"), to: record)
                        }
                    }
                }
            }
        }
    }

    private func session(_ id: String?) -> SessionRecord? {
        sessions.first { $0.info.id == id }
    }

    private func broadcast(_ envelope: Envelope, session: SessionRecord) {
        for key in session.subscribers {
            connections[key]?.send(envelope)
        }
    }
    /// Nothing to say is nothing sent.
    private func broadcast(_ envelope: Envelope?, session: SessionRecord) {
        if let envelope { broadcast(envelope, session: session) }
    }

    private func broadcastSessions() {
        let envelope = Envelope.sessions(sessions.map(\.info))
        for connection in connections.values where connection.authenticated { connection.send(envelope) }
    }

    /// What agents are on offer, after that changed (a key was entered).
    private func broadcastCatalogs() {
        let envelope = Envelope.catalogs(catalogs())
        for connection in connections.values where connection.authenticated { connection.send(envelope) }
    }

    /// The list, once, after a burst: a turn writes a row per tool call.
    private var sessionsBroadcastPending = false
    private func broadcastSessionsSoon() {
        guard !sessionsBroadcastPending else { return }
        sessionsBroadcastPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.sessionsBroadcastPending = false
            self.broadcastSessions()
        }
    }

    /// Restarts the app, optionally installing `bundle` over ourselves
    /// first, and asks the new one to carry on `carrying`. Returns what went
    /// wrong, or nil — on success this process is on its way out.
    ///
    /// The relauncher is a plain shell that waits for our pid to go away: it
    /// is reparented to launchd when we exit, so nothing it does depends on
    /// us still being here.
    @discardableResult
    public func relaunch(installing bundle: String?, carrying: [String]) -> String? {
        let destination = Bundle.main.bundlePath
        var install = ""
        if let bundle, !bundle.isEmpty {
            let source = (bundle as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source + "/Contents/MacOS") else {
                return "No app bundle at \(source)"
            }
            let identifier = (Bundle(path: source)?.bundleIdentifier ?? "")
            guard identifier == Bundle.main.bundleIdentifier else {
                return "\(source) is \(identifier.isEmpty ? "not an app" : identifier), not \(Bundle.main.bundleIdentifier ?? "this app")"
            }
            if source != destination {
                install = "rm -rf \(Self.shellQuoted(destination)) && cp -R \(Self.shellQuoted(source)) \(Self.shellQuoted(destination)) || exit 1\n"
            }
        }
        // The sessions that are mid-turn are written down as such: the flag
        // is what the next launch reads to know a reply is owed.
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // Empty means the default: everything that was running. A caller
        // that names sessions gets exactly those.
        let list = carrying.joined(separator: ",")
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(install)open -a \(Self.shellQuoted(destination)) --args --resume-sessions \(Self.shellQuoted(list))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        // Somewhere to look when a relaunch does not come back.
        let logPath = "/tmp/visor-relaunch.log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        do { try p.run() } catch { return "Could not start the relauncher: \(error.localizedDescription)" }
        // endAll runs from applicationWillTerminate; the agents stop the
        // same way they do for any quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApplication.shared.terminate(nil) }
        return nil
    }

    /// A path as one shell word.
    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Every session as a markdown table: the computer, each project (its
    /// name and the folder it is), and the sessions in it with the id that
    /// resumes them. What to paste into notes, or into another agent.
    public func sessionTable() -> String {
        let computer = hostName
        var rows: [String] = [
            "| Computer | Project | Folder | Session | Agent | ID |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        let ordered = sessions.sorted {
            ($0.info.cwd, $0.info.title.lowercased()) < ($1.info.cwd, $1.info.title.lowercased())
        }
        for record in ordered {
            let info = record.info
            let folder = HostFolders.resolve(info.cwd)
            let project = (folder as NSString).lastPathComponent
            let title = info.title.isEmpty ? info.agent.title : info.title
            // The agent's own id, not ours: it is the one that resumes the
            // conversation in a terminal. Empty until the first turn.
            let id = record.process.resumeID ?? info.id
            let state = info.archived ? " (archived)" : ""
            rows.append("| \(computer) | \(project) | `\(folder)` | \(title)\(state) | \(info.agent.title) | `\(id)` |")
        }
        if ordered.isEmpty { rows.append("| \(computer) | — | — | no sessions | — | — |") }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Ends every session (the app is quitting). What was running is
    /// written down as running, so the next launch can carry it on: this is
    /// the record of the shutdown, however the app was quit.
    public func endAll() {
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // Waited for, not merely asked: `stop` arms the force step on a
        // timer, and we are gone long before it fires, which leaves the
        // agent alive and parentless.
        for session in sessions { session.process.stopAndWait(deadline: 4) }
    }
}

/// One client's WebSocket.
@MainActor
final class ClientConnection {
    let connection: NWConnection
    var authenticated = false
    /// Which client this is, as it named itself at login: whose window a
    /// terminal may be drawn for.
    var clientID = ""
    var onMessage: ((Envelope) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8), let envelope = Envelope.decode(text) {
                    self.onMessage?(envelope)
                }
                if error != nil || context?.isFinal == true { self.finish(); return }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .close { self.finish(); return }
                self.receive()
            }
        }
    }

    func send(_ envelope: Envelope) {
        guard !closed else { return }
        let data = Data(envelope.encoded().utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connection.cancel()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}
