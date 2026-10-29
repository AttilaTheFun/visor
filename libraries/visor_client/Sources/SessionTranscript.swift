import MessageCache
import Observation
import SwiftUI
import VisorProtocol
import VisorServices

/// A session's transcript as the client sees it.
///
/// Views are told of changes a frame at a time, not one by one: sending a
/// message sets off a burst — the message shown, the computer's copy of
/// it, the agent's own record of it, thinking, the reply starting — and a
/// view redrawn for each, each redraw scrolling and animating, jumps.
/// The first change after a quiet frame is told at once; the rest of a
/// frame's changes are told together at its end. What the user just did
/// starts a frame over (`flush`): what the computer says back to a send
/// waits until the thread has finished moving for it. Coming back to a
/// thread that moved on, the pages it catches up on are told together
/// once the last is in, and at most once a frame until then.
///
/// Observed (Observation) through one counter, `tick`, advanced when views
/// are told: every property a view reads touches it, and the state itself
/// is kept untracked, so a frame's changes reach a view once.
@MainActor
@Observable
public final class SessionTranscript {
    /// Advanced when views are told of changes (`announce`).
    private var tick = 0
    /// How often, at most, views are told of changes (nanoseconds): once a
    /// second, longer than the thread's own motions (a third to half a
    /// second), so an update does not land in the middle of one.
    public static var frame: UInt64 = 1_000_000_000
    /// A frame is running: changes wait for its end.
    @ObservationIgnored private var framing = false
    /// Something changed since views were last told.
    @ObservationIgnored private var dirty = false
    /// How many times views have been told, for tests.
    @ObservationIgnored private(set) var announced = 0
    /// Whether a frame is running, for tests.
    var inFrame: Bool { framing }
    /// What ends the frame running.
    @ObservationIgnored private var frameEnds: Task<Void, Never>?
    /// A catch-up is under way (a client that was away is brought up a
    /// page at a time, each page a request of its own): its pages are not
    /// told as they come, which steps the thread through what it missed,
    /// but at most once a frame, and the whole of it the moment its last
    /// page is in.
    @ObservationIgnored private var catchingUp = false
    /// When views were last told.
    @ObservationIgnored private var lastTold: ContinuousClock.Instant?

    /// Every change comes here.
    private func changed() {
        if framing || catchingUp {
            dirty = true
            if !framing { startFrame() }
            return
        }
        announce()
        startFrame()
    }

    private func announce() {
        dirty = false
        announced += 1
        lastTold = .now
        tick &+= 1
    }

    /// The last page of a catch-up is in: views are told now, unless they
    /// were told less than half a frame ago (then at the frame's end).
    private func endCatchUp() {
        guard dirty else { return }
        if let lastTold, ContinuousClock.now - lastTold < .nanoseconds(Int64(Self.frame / 2)) { return }
        announce()
        startFrame()
    }

    private func startFrame() {
        framing = true
        frameEnds?.cancel()
        frameEnds = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionTranscript.frame)
            guard !Task.isCancelled, let self else { return }
            if self.dirty { self.announce(); self.startFrame() } else { self.framing = false }
        }
    }

    /// Tells views now, whatever the frame: for what the user just did.
    /// A frame starts from here: the computer's answer to a send — its
    /// copy of the message, the turn starting, thinking — is told a whole
    /// frame later, once the thread has moved for the send, not whenever
    /// the frame that was running ends, which is in the middle of it.
    public func flush() {
        if dirty { announce() }
        startFrame()
    }

    /// The id a row is shown under. A message keeps one identity through
    /// its copies — the one sent from here, the computer's copy, the
    /// agent's own record of it — so the view sees one row that changes,
    /// not one removed and another inserted.
    @ObservationIgnored private var displayIDs: [String: String] = [:]
    public func displayID(of entry: TranscriptEntry) -> String { displayIDs[entry.id] ?? entry.id }

    /// The ids of the rows the thread shows, in order: the record's under
    /// their display ids, then what was just sent and is shown.
    var shownIDs: [String] { _entries.map(displayID(of:)) + _sending.filter(\.shown).map(\.id) }

    /// A rebuilt set of rows: a row that is new here and has the same role
    /// and words as one that went takes that one's display id.
    private func carryDisplayIDs(from old: [TranscriptEntry], to new: [TranscriptEntry]) {
        let kept = Set(new.map(\.id))
        var gone: [String: [String]] = [:]
        for row in old where !kept.contains(row.id) { gone[Self.likeness(row), default: []].append(displayID(of: row)) }
        guard !gone.isEmpty else { return }
        let before = Set(old.map(\.id))
        for row in new where displayIDs[row.id] == nil && !before.contains(row.id) {
            let key = Self.likeness(row)
            guard var ids = gone[key], !ids.isEmpty else { continue }
            displayIDs[row.id] = ids.removeFirst()
            gone[key] = ids
        }
    }

    static func likeness(_ entry: TranscriptEntry) -> String {
        entry.role.rawValue + "|" + AgentServerConnection.trimmed(entry.text)
    }

    /// The record's rows, as synced: all the thread shows. What streams
    /// is not kept or drawn — the sync answers as soon as the record moves.
    /// The session as the computer's list has it, told with the rest of
    /// the transcript a frame at a time: the chat reads it here, not in
    /// the list, which changes whenever any session on the computer does
    /// anything and would redraw the thread each time.
    @ObservationIgnored private var _info: SessionInfo? = nil
    public var info: SessionInfo? {
        get { _ = tick; return _info }
        set {
            guard newValue != _info else { return }
            _info = newValue
            changed()
        }
    }

    /// Its forks and branches still going, as the list has them, told the
    /// same way: the chat's rows for them change with them alone.
    @ObservationIgnored private var _children: [SessionInfo] = []
    public var children: [SessionInfo] {
        get { _ = tick; return _children }
        set {
            guard newValue != _children else { return }
            _children = newValue
            changed()
        }
    }

    @ObservationIgnored private var _entries: [TranscriptEntry] = []
    public var entries: [TranscriptEntry] {
        get { _ = tick; return _entries }
        set { _entries = newValue; changed() }
    }
    @ObservationIgnored private var _activity: String? = nil
    public var activity: String? {
        get { _ = tick; return _activity }
        set { _activity = newValue; changed() }
    }
    @ObservationIgnored private var _busy: Bool = false
    public var busy: Bool {
        get { _ = tick; return _busy }
        set { _busy = newValue; changed() }
    }
    @ObservationIgnored private var _error: String? = nil
    public var error: String? {
        get { _ = tick; return _error }
        set { _error = newValue; changed() }
    }
    /// A sign-in waiting for its code (`/login`): the page to sign in at.
    /// What the user sends next is the code.
    @ObservationIgnored private var _signIn: String? = nil
    public var signIn: String? {
        get { _ = tick; return _signIn }
        set {
            guard newValue != _signIn else { return }
            _signIn = newValue
            // The `/login` that started it is taken.
            if newValue != nil { _sending.removeAll { $0.entry.text.hasPrefix("/login") } }
            changed()
        }
    }
    /// A tool call waiting for Allow or Deny.
    @ObservationIgnored private var _pendingApproval: ApprovalRequest? = nil
    public var pendingApproval: ApprovalRequest? {
        get { _ = tick; return _pendingApproval }
        set { _pendingApproval = newValue; changed() }
    }
    /// The transcript has been replayed once; before that the view shows a spinner.
    @ObservationIgnored private var _loaded: Bool = false
    public var loaded: Bool {
        get { _ = tick; return _loaded }
        set { _loaded = newValue; changed() }
    }
    /// The revision of the rows held, from the last sync; what the next
    /// sync asks to go past.
    @ObservationIgnored public var revision = 0
    /// Whether the thread goes back further than what has been sent.
    @ObservationIgnored private var _hasEarlier: Bool = false
    public var hasEarlier: Bool {
        get { _ = tick; return _hasEarlier }
        set { _hasEarlier = newValue; changed() }
    }
    /// A page of earlier rows is on its way (from the cache or the server).
    @ObservationIgnored var loadingEarlier = false
    /// The row the server was asked for the rows before, until it answers.
    @ObservationIgnored var earlierAsked: String?
    /// The server has said there is nothing before the first row shown.
    @ObservationIgnored var reachedStart = false
    /// Something to tell the user about the session, until they
    /// acknowledge it: that it was forked elsewhere and the chat now
    /// follows the newer branch.
    @ObservationIgnored private var _notice: String? = nil
    public var notice: String? {
        get { _ = tick; return _notice }
        set { _notice = newValue; changed() }
    }
    /// A message sent from here and not yet on the record: the composer
    /// shows it as sending until the synced record carries it.
    public struct Outgoing: Identifiable, Equatable {
        public let id: String
        public let entry: TranscriptEntry
        /// The transcript revision when this was sent; the confirming
        /// message must arrive after it, so an identical message from
        /// before does not settle it.
        public let sinceRevision: Int
        /// Shown in the thread at once, as its last row, until the record
        /// carries it (it went to an idle agent); a message that waits for
        /// the turn to end is shown in the composer's queue instead.
        public var shown = false
        /// The user's rows already on the record when this was sent: none
        /// of them is this message, whatever its words (the same thing
        /// said twice is two messages).
        public var had: Set<String> = []
    }
    @ObservationIgnored private var _sending: [Outgoing] = []
    public var sending: [Outgoing] {
        get { _ = tick; return _sending }
        set { _sending = newValue; changed() }
    }

    /// The generation of the rows held; a different one in an answer means
    /// the rows were rebuilt and the answer is the whole, not a delta.
    @ObservationIgnored public var generation = -1
    /// Told what a sync brought, as the cache is to write it, with where
    /// the sync then stands. Set by the connection that owns this.
    @ObservationIgnored var keep: ((_ write: CacheWrite, _ state: SyncState) -> Void)?

    /// What a sync changes in the cache: the cache keeps every row synced
    /// or paged to, so a change is written as a change — never the rows in
    /// memory in place of the history kept.
    enum CacheWrite: Equatable {
        /// Rows new at the end or changed in place, and rows gone.
        case upsert([TranscriptEntry], removed: [String])
        /// Everything from the row `from` on is these rows (a row moved,
        /// inserted or removed there); `all`, the rows held, if the cache
        /// does not have that row.
        case rewrite(from: String, [TranscriptEntry], all: [TranscriptEntry])
        /// Everything after the row `after` is these rows (the whole, in a
        /// new generation, carrying on the history kept); the rows alone,
        /// if the cache does not have that row.
        case follow(after: String, [TranscriptEntry])
        /// The history is these rows, and nothing before them.
        case replace([TranscriptEntry])
    }

    /// A client behind the server catches up a page at a time (`later`):
    /// the revision it asks past and the last row it was given, and the
    /// revision the server had when it began, which it holds once the
    /// last page is in.
    struct CatchUp: Equatable {
        var since: Int
        var after: String
        var revision: Int
    }
    @ObservationIgnored var catchUp: CatchUp?
    /// Let go of when the session was left: refilled from the cache, and
    /// synced again, when it is opened.
    @ObservationIgnored var released = false

    /// Whether a sync's answer brings anything: the first answer, rows
    /// past the revision held, or the rows as a whole in another
    /// generation. A session just started or resumed from here is shown
    /// as loaded at revision 0 before its first answer, and its rows (a
    /// resumed conversation's, imported by the computer) may come at
    /// revision 0 too: they come whole, in the computer's generation.
    func takes(_ envelope: Envelope) -> Bool {
        !loaded || (envelope.revision ?? -1) != revision || envelope.reset == true || envelope.later == true || catchUp != nil
            || (envelope.generation.map { $0 != generation } ?? false)
    }

    func sync(_ envelope: Envelope) {
        // The first answer is what an opening thread waits for ("Loading…"):
        // told at once, as a send is, not at the end of a frame already
        // running.
        let first = !_loaded
        let rows = envelope.entries ?? []
        // A page with more to follow is held from views; the last ends the
        // catch-up (`catchingUp`).
        let wasCatchingUp = catchingUp
        catchingUp = envelope.later == true && !rows.isEmpty
        let write: CacheWrite
        // The rows replaced by the answer's, not merged with them.
        var replaced = false
        if envelope.reset != true, let generation = envelope.generation, generation == self.generation, loaded {
            // A delta: the rows removed since the revision held go; each
            // row new, changed or moved since goes after the row it follows
            // on the computer. Rows appended at the end, or changed in
            // place, are written to the cache as they are; anything else
            // rewrites the cache from the first row whose place changed.
            let old = entries
            var next = entries
            var structural = false
            let removed = envelope.removed ?? []
            if !removed.isEmpty {
                let gone = Set(removed)
                next.removeAll { gone.contains($0.id) }
                structural = next.count != old.count
            }
            let after = envelope.after ?? []
            for (offset, row) in rows.enumerated() {
                let anchor = offset < after.count ? after[offset] : nil
                if let index = next.firstIndex(where: { $0.id == row.id }) {
                    let before = index > 0 ? next[index - 1].id : ""
                    if anchor == nil || anchor == before { next[index] = row; continue }
                    next.remove(at: index)
                    structural = true
                }
                if let anchor, anchor.isEmpty {
                    next.insert(row, at: 0)
                    structural = true
                } else if let anchor, let index = next.firstIndex(where: { $0.id == anchor }) {
                    if index != next.index(before: next.endIndex) { structural = true }
                    next.insert(row, at: index + 1)
                } else {
                    next.append(row)
                }
            }
            // The first place where the rows held differ from before.
            let diverge = (0..<min(old.count, next.count)).first { old[$0].id != next[$0].id } ?? (next.count < old.count ? next.count : nil)
            if structural, let first = diverge, first < old.count {
                write = .rewrite(from: old[first].id, Array(next[min(first, next.count)...]), all: next)
            } else {
                // Rows that went from what the cache keeps beyond the
                // rows held go too.
                write = .upsert(rows, removed: removed)
            }
            entries = next
        } else {
            replaced = true
            carryDisplayIDs(from: entries, to: rows)
            // The whole carries on the history held when its first row
            // follows a row held (`follows`): the rows before it stay, here
            // and in the cache. Otherwise it is the history.
            if let follows = envelope.follows, !follows.isEmpty, !rows.isEmpty {
                if let index = entries.firstIndex(where: { $0.id == follows }) {
                    entries = Array(entries[...index]) + rows
                    replaced = false
                } else {
                    entries = rows
                }
                write = .follow(after: follows, rows)
            } else {
                entries = rows
                write = .replace(rows)
            }
            generation = envelope.generation ?? generation
            // Earlier pages start over from these rows.
            loadingEarlier = false
            earlierAsked = nil
            reachedStart = false
        }
        // Catching up: the revision held stays where it was until the last
        // page, so a sync cut short asks again from there.
        if envelope.later == true, let last = rows.last?.id {
            catchUp = CatchUp(since: catchUp?.since ?? revision, after: last, revision: catchUp?.revision ?? (envelope.revision ?? revision))
        } else {
            revision = catchUp?.revision ?? envelope.revision ?? revision
            catchUp = nil
        }
        // The server's word on rows before its own last ones: the whole
        // answer's says what is before it; a delta's only that there are
        // rows before the server's last page, which the rows held may
        // already go past (pages loaded since).
        if replaced || entries.isEmpty {
            hasEarlier = envelope.more ?? false
        } else if envelope.more == true, !reachedStart {
            hasEarlier = true
        }
        if envelope.entries?.contains(where: { $0.role == .user }) == true { error = nil }
        loaded = true
        keep?(write, SyncState(revision: revision, generation: generation))
        settleSending()
        if first { flush() } else if wasCatchingUp && !catchingUp { endCatchUp() }
    }

    /// Lets go of the rows held, when the session is left: the cache keeps
    /// them, and the session reads its latest rows from there when it is
    /// opened again. What is on its way, or still to be told, stays.
    func release() {
        entries = []
        displayIDs = [:]
        loaded = false
        // Asked for whole again, unless the cache says where it stood.
        revision = 0
        generation = -1
        catchUp = nil
        catchingUp = false
        loadingEarlier = false
        earlierAsked = nil
        reachedStart = false
        hasEarlier = false
    }

    /// Rows from before the first shown, put in front of it; `more`, whether
    /// there are rows before these. How many were new.
    @discardableResult
    func putEarlier(_ rows: [TranscriptEntry], more: Bool) -> Int {
        let held = Set(entries.map(\.id))
        let older = rows.filter { !held.contains($0.id) }
        if !older.isEmpty { entries = older + entries }
        hasEarlier = more
        loadingEarlier = false
        return older.count
    }

    /// What the server tells the user about the session. A new one answers
    /// a command that has no row of its own (Codex's /goal alone,
    /// /compact): that command is taken, no longer sending.
    func take(notice new: String?) {
        if let new, new != notice { sending.removeAll { $0.entry.text.hasPrefix("/") } }
        notice = new
    }

    /// Drops an outgoing goal command once the session's goal says it was
    /// taken: `/goal <objective>` when the goal is that objective, `/goal
    /// clear` when there is none. Codex takes a goal as a request of its
    /// own, and its log may never write the command back (codex 0.16x set
    /// one with no row at all), so the record's copy cannot be waited for.
    func settleGoal(_ goal: String?) {
        guard !sending.isEmpty else { return }
        sending.removeAll { out in
            let text = out.entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("/goal ") else { return false }
            let objective = text.dropFirst("/goal ".count).trimmingCharacters(in: .whitespaces)
            if objective == "clear" { return goal == nil }
            if objective == "pause" || objective == "resume" { return false }
            guard let goal else { return false }
            return CommandWords.same("/goal " + goal, text)
        }
    }

    /// What the agent has been handed and has not written to its log yet
    /// (the session's `delivered`: a message that left the queue while
    /// Codex compacts its context, say), as the user's rows after the
    /// record's: none the thread shows already (sent from here to an idle
    /// agent, or the record's last message of the user's, in its words).
    public var deliveredEntries: [TranscriptEntry] {
        let delivered = info?.delivered ?? []
        guard !delivered.isEmpty else { return [] }
        let shown = sending.filter(\.shown).map(\.entry.text)
        let last = entries.last { $0.role == .user }?.text
        return delivered.enumerated().compactMap { index, text in
            if shown.contains(text) || last == text || last?.hasPrefix(text + "\n\nAttached ") == true { return nil }
            return TranscriptEntry(id: "delivered-\(index)", role: .user, text: text)
        }
    }

    /// Drops an outgoing message once the transcript has moved past when
    /// it was sent and carries an identical message: it is on the record.
    func settleSending() {
        guard !sending.isEmpty else { return }
        func matched(_ text: String, _ recorded: String) -> Bool {
            recorded == text || recorded.hasPrefix(text + "\n\nAttached ") || (text.isEmpty && recorded.hasPrefix("Attached "))
                || CommandWords.same(recorded, text)
        }
        sending.removeAll { out in
            guard revision > out.sinceRevision,
                  let row = entries.last(where: { $0.role == .user && !out.had.contains($0.id) && matched(out.entry.text, $0.text) })
            else { return false }
            // The record's row is this message: shown under its id.
            if displayIDs[row.id] == nil { displayIDs[row.id] = out.id }
            return true
        }
    }
    public init() {}

    /// The newest status label, and the wait before it is shown.
    @ObservationIgnored private var latestActivity: String?
    @ObservationIgnored private var activityFlush: Task<Void, Never>?
    /// Everything streamed as status this turn that is not part of the
    /// record — the tool calls, subagents, shells and thinking as they
    /// were announced — in order, for the footer under the thread. Cleared
    /// when the turn ends: the record's rows carry what was done.
    @ObservationIgnored private var _turnStatus: [StatusItem] = []
    public var turnStatus: [StatusItem] {
        get { _ = tick; return _turnStatus }
        set { _turnStatus = newValue; changed() }
    }

    /// Status labels come in bursts — a tool call a moment — and a row
    /// redrawn for each one flickers, its spinner with it. The first label
    /// of a turn shows at once, and so does the end of them; in between,
    /// the label settles a few times a second, the newest winning.
    private func setActivity(_ value: String?) {
        latestActivity = value
        if value == nil || activity == nil {
            activityFlush?.cancel()
            activityFlush = nil
            activity = value
            return
        }
        guard activityFlush == nil else { return }
        activityFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.activityFlush = nil
            if self.activity != self.latestActivity { self.activity = self.latestActivity }
        }
    }

    func apply(_ envelope: Envelope) {
        switch envelope.type {
        case "transcript":
            // Over the socket, a transcript carries the session's state;
            // its rows are the record's business, synced over HTTP, and
            // are taken here only before the first sync has answered.
            if !loaded { sync(envelope) }
            activity = envelope.activity
            busy = envelope.busy ?? false
            error = envelope.error
            take(notice: envelope.notice)
        case "ephemeral":
            // Everything that is not the record, on subscribing.
            turnStatus = envelope.status ?? []
            activity = envelope.activity
            latestActivity = envelope.activity
            busy = envelope.busy ?? false
            pendingApproval = envelope.approval
            signIn = envelope.signIn
            take(notice: envelope.notice)
        case "status":
            turnStatus = envelope.status ?? []
        case "delta", "streamEnd":
            // A reply being written: not drawn. Its row comes with the sync.
            break
        case "entry":
            // Rows come from the record, over HTTP; the socket's copy is
            // not taken, so there is one source of them.
            break
        case "activity":
            setActivity(envelope.activity)
        case "busy":
            busy = envelope.busy ?? false
            if !busy { pendingApproval = nil }
        case "failure":
            error = envelope.message
            // What was on its way did not arrive.
            sending.removeAll()
        case "notice":
            take(notice: envelope.notice)
        case "approval":
            pendingApproval = envelope.approval
        default:
            break
        }
    }
}
