// One agent session as the server holds it: its process, its transcript as
// the agent's own log has it, what is streaming and what waits, and who
// watches. The server applies an agent's events to a record and tells its
// subscribers what the record then says.

import ClaudeTranscript
import Foundation
import MessageCache
import VisorProtocol

/// One agent session on the host: its process, its transcript, who watches it.
@MainActor
public final class SessionRecord: ObservableObject {
    public private(set) var info: SessionInfo
    public private(set) var entries: [TranscriptEntry] = [] {
        didSet {
            revision += 1
            stamp(from: oldValue)
            noteMarks(lookingBack: false)
            onRevision?()
        }
    }
    /// Counts up with every change to the rows; what a client syncing
    /// over HTTP compares to.
    public private(set) var revision = 0
    /// Counts up when a client holding an older revision can no longer be
    /// brought up to date by a delta (the record of removed rows was let
    /// go): it takes the rows as a whole.
    /// Starts somewhere new with each run of the server, so a client that
    /// synced with an earlier run takes the rows as a whole.
    public private(set) var generation = Int.random(in: 1...Int(Int32.max))
    /// The revision at which each row last changed or moved, so a client is
    /// given only the rows past the revision it holds.
    private var rowSeq: [String: Int] = [:]
    /// Rows that went, and the revision they went at.
    private var removedAt: [String: Int] = [:]
    /// How many removals are remembered before the record starts again.
    static let rememberedRemovals = 2000

    /// After the rows changed: which rows are new, different or in a new
    /// place (after a different row) since `old`, stamped with this
    /// revision; and which went. A client can take any change as a delta.
    private func stamp(from old: [TranscriptEntry]) {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var oldBefore: [String: String] = [:]
        for index in old.indices.dropFirst() { oldBefore[old[index].id] = old[index - 1].id }
        var present = Set<String>()
        for (index, row) in entries.enumerated() {
            present.insert(row.id)
            removedAt[row.id] = nil
            let before = index > 0 ? entries[index - 1].id : nil
            if oldByID[row.id] != row || oldBefore[row.id] != before { rowSeq[row.id] = revision }
        }
        for row in old where !present.contains(row.id) {
            rowSeq[row.id] = nil
            removedAt[row.id] = revision
        }
        if removedAt.count > Self.rememberedRemovals { startNewGeneration() }
    }

    /// Clients start again from the rows as they are: a delta can no
    /// longer bring them here (or should not — the thread is a new branch).
    func startNewGeneration() {
        removedAt = [:]
        generation += 1
    }

    /// Sets the rows as a change would, for tests.
    func replaceEntriesForTesting(_ rows: [TranscriptEntry]) { entries = rows }

    /// The rows changed since a revision, each with the row it follows
    /// ("" for the first), and the rows removed since — or every row, for
    /// a revision from before the generation began.
    func rows(since: Int) -> (rows: [TranscriptEntry], after: [String], removed: [String]) {
        let start = max(0, entries.count - Self.servedRows)
        var rows: [TranscriptEntry] = []
        var after: [String] = []
        // A row never stamped came with the record, before any revision.
        for index in start..<entries.count where (rowSeq[entries[index].id] ?? 0) > since {
            rows.append(entries[index])
            after.append(index > 0 ? entries[index - 1].id : "")
        }
        let removed = removedAt.filter { $0.value > since }.map(\.key)
        return (rows, after, removed)
    }

    /// The turn's status lines so far — tool calls, subagents, shells,
    /// thinking — as announced, kept here so a client that subscribes
    /// mid-turn gets all of them. Cleared when the turn ends.
    private var turn = TurnStatus()
    /// The slash commands the agent listed when it last ran here.
    var commands: [SlashCommand] = []
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
    /// The agent's events being handed to the server, one at a time and in
    /// the order the agent gave them.
    private var listening: Task<Void, Never>?
    var isBound: Bool { listening != nil }
    /// The agent that ran before this one has been told to go and is not
    /// yet gone: what is said waits, so that two agents never hold the
    /// session at once.
    var held = false
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
    /// Finding the file, then hearing what the indexer says of it.
    private var following: Task<Void, Never>?
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
    /// restart (the file is found and read again).
    func followFile() {
        guard let id = process.resumeID else { return }
        stopFollowing()
        let agent = info.agent, cwd = info.cwd, session = info.id
        following = Task { [weak self] in
            // Not written yet (the agent announces its id before its first
            // record): looked for again shortly, for as long as a first
            // turn could take.
            var log = AgentLog.locate(agent: agent, id: id, cwd: cwd)
            var looks = 0
            while log == nil, looks < 240 {
                looks += 1
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                log = AgentLog.locate(agent: agent, id: id, cwd: cwd)
            }
            guard let log, !Task.isCancelled else { return }
            // The cache catches up with the file off the main actor and
            // hands over the window to show; then each line as the agent
            // writes it.
            let indexer = SessionIndexer(store: ServerCache.shared, sessionID: session, url: log.url, window: Self.servedRows, format: log.format)
            self?.indexer = indexer
            for await event in indexer.events() {
                guard let self else { return }
                switch event {
                case .loaded(let loaded): self.apply(loaded: loaded)
                case .lines(let lines): self.apply(lines: lines)
                }
            }
        }
    }

    /// The file is no longer read: the session has ended, or is about to
    /// be read again.
    func stopFollowing() {
        following?.cancel()
        following = nil
        indexer = nil
    }

    /// The file as read: the conversation is the branch that holds its
    /// last line — what an agent resuming now would continue. If the last
    /// prompt this chat showed is on a branch beside it, the session was
    /// forked elsewhere and moved on; the chat follows, and says so.
    private func apply(loaded: SessionIndexer.Loaded) {
        var forked = false
        if let last = shownPrompts.last, loaded.abandoned.contains(last) {
            notice = Self.forkNotice(lost: shownPrompts.filter { loaded.abandoned.contains($0) }.count)
            forked = true
        }
        let told = notice != nil
        shownPrompts = Array(loaded.prompts.suffix(Self.rememberedPrompts))
        moreBefore = loaded.more
        let before = entries.map(\.id)
        if !loaded.rows.isEmpty {
            entries = loaded.rows
            settle(in: entries)
        }
        // A goal or loop set before the rows shown: the cache has it.
        noteMarks(lookingBack: true)
        // Forked elsewhere: the thread is another branch. Clients start
        // again from it (a new generation, answered whole, with `reset`)
        // and are told why (the notice).
        if forked { startNewGeneration() }
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

    /// Words sent to an agent that writes its own log, which the log has
    /// not written yet: kept here, not as rows — the transcript is the log.
    /// Each with how many of the log's user rows had the same words when
    /// it was sent, so the same words sent again are told apart.
    private(set) var unwritten: [(text: String, seen: Int)] = []

    /// How many of these rows are the user's, in these words.
    private func userRows(_ rows: [TranscriptEntry], saying text: String) -> Int {
        rows.filter { $0.role == .user && Self.sameWords($0.text, text) }.count
    }

    /// Drops the words sent that these rows now carry.
    func settle(in rows: [TranscriptEntry]) {
        unwritten.removeAll { userRows(rows, saying: $0.text) > $0.seen }
    }

    /// Whether a prompt in the file is one this server sent — words it has
    /// sent and not yet seen written — or one the agent fed itself (a
    /// command's expansion, a reminder). A terminal's prompts are all the
    /// user's own.
    private func isOurs(prompt record: ClaudeRecord?) -> Bool {
        if info.mode.isTUI { return true }
        guard case .user(let text, _)? = record?.kind else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") { return true }
        return unwritten.contains { Self.sameWords(trimmed, $0.text) }
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
        case .title, .goal: nil
        }
    }

    /// Follows the file the first time anyone looks at a resumed session.
    func followFileIfNeeded() {
        guard indexer == nil else { return }
        followFile()
    }

    /// Whether the file's copy of a user message is the server's: the
    /// same words, or the same words followed by the attached pictures'
    /// paths the server added for the agent.
    private static func sameWords(_ fileText: String, _ rowText: String) -> Bool {
        // Both trimmed: the file keeps the prompt without the whitespace
        // around it, and a message typed on a phone often ends in a space.
        let file = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = rowText.trimmingCharacters(in: .whitespacesAndNewlines)
        return file == row || (!row.isEmpty && file.hasPrefix(row + "\n\nAttached "))
            || (row.isEmpty && file.hasPrefix("Attached "))
    }

    /// Puts one row from the file into the transcript: a new row goes on the
    /// end, a row it already has (a reply growing) changes in place.
    private func take(fileRow row: TranscriptEntry) -> Bool {
        if row.role == .assistant { dropStream(carriedBy: row.id) }
        if let index = entries.firstIndex(where: { $0.id == row.id }) { entries[index] = row } else { entries.append(row) }
        if row.role == .user { settle(in: entries) }
        noteLatest()
        return true
    }

    /// Keeps the session's summary — the start of its latest message and
    /// when it came — after the transcript changed at its end.
    /// The session's goal and loop, as the latest of their marks says:
    /// among the rows held, or (`lookingBack`, on loading) in the cache
    /// for the rows before them.
    private func noteMarks(lookingBack: Bool) {
        let goalPrefixes = ["goal-file-"], loopPrefixes = ["loop-file-"], goalClear = ["/goal clear"]
        var goalMark = entries.reversed().lazy.compactMap(Self.goal(of:)).first
        var loopMark = entries.reversed().lazy.compactMap(Self.loop(of:)).first
        if lookingBack {
            if goalMark == nil {
                goalMark = ServerCache.shared.lastMessage(in: info.id, idPrefixes: goalPrefixes, userTexts: goalClear).flatMap(Self.goal(of:))
            }
            if loopMark == nil {
                loopMark = ServerCache.shared.lastMessage(in: info.id, idPrefixes: loopPrefixes).flatMap(Self.loop(of:))
            }
        }
        var next = info
        if let goalMark { next.goal = goalMark }
        if let loopMark { next.loopWake = loopMark.wake; next.loopCron = loopMark.cron }
        guard next.goal != info.goal || next.loopWake != info.loopWake || next.loopCron != info.loopCron else { return }
        info = next
        onInfoChanged?()
    }

    /// Whether the goal just gone was met, not cleared: the latest goal row
    /// is a met one.
    func goalWasMet(_ goal: String) -> Bool {
        guard let row = entries.reversed().first(where: { Self.goal(of: $0) != nil }) else { return false }
        return row.toolName == "goal-met"
    }

    /// The goal a row says the session has now (nil: none), if it is a goal's.
    static func goal(of row: TranscriptEntry) -> String?? {
        if row.role == .user, row.text == "/goal clear" || row.text.hasPrefix("/goal clear ") { return .some(nil) }
        guard row.role == .tool else { return nil }
        switch row.toolName {
        case "goal": return .some(row.text)
        case "goal-met": return .some(nil)
        default: return nil
        }
    }

    /// The loop a row says the session has now, if it is a loop's mark.
    static func loop(of row: TranscriptEntry) -> (wake: Double?, cron: String?)? {
        guard row.role == .tool, row.toolName == "loop" else { return nil }
        if row.text.hasPrefix("wake "), let time = Double(row.text.dropFirst(5)) { return (time, nil) }
        if row.text.hasPrefix("cron ") { return (nil, String(row.text.dropFirst(5))) }
        return (nil, nil)
    }

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
        // The outbox is written down with the session: what waits to be
        // sent, and the files it carries, survive a restart of the app.
        StoredSession(info: info, entries: Array(entries.suffix(Self.servedRows)), resumeID: process.resumeID, shape: StoredSession.currentShape, interrupted: interrupted, agentPID: process.processID, shownPrompts: Array(shownPrompts.suffix(Self.rememberedPrompts)), notice: notice, queuedImages: queuedImages)
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
            // A wake-up that has come and gone with no next one set: the
            // loop is over.
            if !value, let wake = info.loopWake, wake < Date().timeIntervalSince1970 {
                info.loopWake = nil
                onInfoChanged?()
            }
            if !value {
                info.pendingApproval = nil
                turn.clear()
                // A stream is not cleared by the turn ending: it stays
                // until the record carries its row. Only an agent whose
                // rows never come from a file lets the turn's end clear it.
                if indexer == nil { streams = [] }
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
            return nil
        case .session:
            refreshResume()
            followFile()
            return nil
        case .commands(let list):
            commands = list
            return nil
        case .model(let model):
            // What actually ran, for display only. The user's choice
            // (info.model) is never changed here — a turn that fell back
            // to another model must not make that model stick.
            info.reportedModel = model
            return nil
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
            return nil
        }
    }

    /// The user's words, handed to the agent. Every agent writes them to
    /// its log, which is the transcript: they are remembered as sent until
    /// the log has them, and are no row until then.
    func appendUser(_ text: String, images: [String] = []) {
        error = nil
        unwritten.append((text: text, seen: userRows(entries, saying: text)))
        // The session's summary is the latest thing said, already.
        if let preview = Self.preview(of: TranscriptEntry(id: "", role: .user, text: text)), preview != info.preview {
            info.preview = preview
            info.updated = Date().timeIntervalSince1970
            onInfoChanged?()
        }
    }


    func markEnded() {
        info.ended = true
        info.busy = false
        stopFollowing()
        stopListening()
    }

    /// The outbox: what the user said during a turn, waiting for it to
    /// end — the words in `info.queued` (which clients see), and beside
    /// each the files it came with (already on this Mac, uploaded before
    /// the message was sent). Written down with the session.
    var queuedImages: [[String]] = []

    /// Holds a message, and its files, until the turn ends.
    func enqueue(_ text: String, images: [String] = []) {
        info.queued.append(text)
        queuedImages.append(images)
    }

    /// Takes the outbox, leaving it empty: everything said, in order, as
    /// one message, with every file it carried.
    func takeQueue() -> (text: String, images: [String]) {
        let text = info.queued.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let images = queuedImages.flatMap { $0 }
        info.queued = []
        queuedImages = []
        return (text, images)
    }

    /// Drops one queued message and its files, or all of them.
    func unqueue(_ text: String?) {
        guard let text else { info.queued = []; queuedImages = []; return }
        guard let index = info.queued.firstIndex(of: text) else { return }
        info.queued.remove(at: index)
        if index < queuedImages.count { queuedImages.remove(at: index) }
    }

    /// The folder the session runs in, after the project moved.
    func setCWD(_ cwd: String) { info.cwd = cwd }

    /// Swaps in an agent built for the new folder; the transcript stays.
    func replaceProcess(_ replacement: AgentProcess) {
        stopListening()
        process = replacement
    }

    /// Hands each of the agent's events to `handle`, in order, from now
    /// until the agent is replaced.
    func listen(_ handle: @escaping (AgentEvent) -> Void) {
        let events = process.events
        listening?.cancel()
        listening = Task { for await event in events { handle(event) } }
    }

    /// What the agent says from here on is not heard.
    func stopListening() {
        listening?.cancel()
        listening = nil
    }

    func setPermissions(skip: Bool) { info.skipPermissions = skip; process.skipPermissions = skip }

    /// The agent shim's connection waiting for the answer, by request id.
    var approvalWaiters: [String: ClientConnection] = [:]

    func setPendingApproval(_ request: ApprovalRequest?) { info.pendingApproval = request }

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
        let delta = since.map { rows(since: $0) }
        var e = Envelope.transcript(session: info.id, entries: delta?.rows ?? Array(entries.suffix(Self.servedRows)), streaming: streaming,
                                    activity: activity, busy: info.busy, error: error)
        if let delta {
            e.after = delta.after
            e.removed = delta.removed
        } else {
            // The rows as a whole: the client replaces what it holds.
            e.reset = true
        }
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
    func earlier(before id: String) async -> Envelope {
        var e = Envelope(type: "earlier")
        e.session = info.id
        // From what is here first; the cache holds what is before that.
        if let index = entries.firstIndex(where: { $0.id == id }), index > 0 {
            let start = max(0, index - Self.servedRows)
            e.entries = Array(entries[start..<index])
            e.more = start > 0 || moreBefore
            return e
        }
        guard let indexer, let first = entries.first?.id else {
            e.entries = []
            e.more = false
            return e
        }
        let page = await indexer.earlier(before: first, limit: Self.servedRows)
        e.entries = page.rows
        e.more = page.more
        return e
    }
}
