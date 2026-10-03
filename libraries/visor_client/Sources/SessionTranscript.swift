import SwiftUI
import MessageCache
import VisorProtocol
import VisorServices

/// A session's transcript as the client sees it.
///
/// Views are told of changes a frame at a time, not one by one: sending a
/// message sets off a burst — the message shown, the computer's copy of
/// it, the agent's own record of it, thinking, the reply starting — and a
/// view redrawn for each, each redraw scrolling and animating, jumps.
/// The first change after a quiet frame is told at once; the rest of a
/// frame's changes are told together at its end.
@MainActor
public final class SessionTranscript: ObservableObject {
    /// How often, at most, views are told of changes (nanoseconds).
    public static var frame: UInt64 = 500_000_000
    /// A frame is running: changes wait for its end.
    private var framing = false
    /// Something changed since views were last told.
    private var dirty = false
    /// How many times views have been told, for tests.
    private(set) var announced = 0
    /// Whether a frame is running, for tests.
    var inFrame: Bool { framing }

    /// Every change comes here.
    private func changed() {
        if framing { dirty = true; return }
        announce()
        startFrame()
    }

    private func announce() {
        dirty = false
        announced += 1
        objectWillChange.send()
    }

    private func startFrame() {
        framing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: SessionTranscript.frame)
            guard let self else { return }
            if self.dirty { self.announce(); self.startFrame() } else { self.framing = false }
        }
    }

    /// Tells views now, whatever the frame: for what the user just did.
    public func flush() {
        guard dirty else { return }
        announce()
    }

    /// The id a row is shown under. A message keeps one identity through
    /// its copies — the one sent from here, the computer's copy, the
    /// agent's own record of it — so the view sees one row that changes,
    /// not one removed and another inserted.
    private var displayIDs: [String: String] = [:]
    public func displayID(of entry: TranscriptEntry) -> String { displayIDs[entry.id] ?? entry.id }

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
    public var entries: [TranscriptEntry] = [] { didSet { changed() } }
    public var activity: String? { didSet { changed() } }
    public var busy = false { didSet { changed() } }
    public var error: String? { didSet { changed() } }
    /// A tool call waiting for Allow or Deny.
    public var pendingApproval: ApprovalRequest? { didSet { changed() } }
    /// The transcript has been replayed once; before that the view shows a spinner.
    public var loaded = false { didSet { changed() } }
    /// The revision of the rows held, from the last sync; what the next
    /// sync asks to go past.
    public var revision = 0
    /// Whether the thread goes back further than what has been sent.
    public var hasEarlier = false { didSet { changed() } }
    /// Something to tell the user about the session, until they
    /// acknowledge it: that it was forked elsewhere and the chat now
    /// follows the newer branch.
    public var notice: String? { didSet { changed() } }
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
    public var sending: [Outgoing] = [] { didSet { changed() } }

    /// The generation of the rows held; a different one in an answer means
    /// the rows were rebuilt and the answer is the whole, not a delta.
    public var generation = -1
    /// Told what a sync brought — the whole, or rows new or changed — so
    /// the cache keeps it. Set by the connection that owns this.
    var keep: ((_ whole: Bool, _ rows: [TranscriptEntry], _ state: SyncState) -> Void)?
    /// Told rows that came from before the first shown.
    var keepEarlier: (([TranscriptEntry]) -> Void)?

    /// Whether a sync's answer brings anything: the first answer, rows
    /// past the revision held, or the rows as a whole in another
    /// generation. A session just started or resumed from here is shown
    /// as loaded at revision 0 before its first answer, and its rows (a
    /// resumed conversation's, imported by the computer) may come at
    /// revision 0 too: they come whole, in the computer's generation.
    func takes(_ envelope: Envelope) -> Bool {
        !loaded || (envelope.revision ?? -1) != revision || envelope.reset == true
            || (envelope.generation.map { $0 != generation } ?? false)
    }

    func sync(_ envelope: Envelope) {
        let rows = envelope.entries ?? []
        let whole: Bool
        var kept = rows
        if envelope.reset != true, let generation = envelope.generation, generation == self.generation, loaded {
            // A delta: the rows removed since the revision held go; each
            // row new, changed or moved since goes after the row it follows
            // on the computer. Only rows appended at the end, or changed in
            // place, leave the cache's copy right as it is; otherwise it
            // takes the rows as a whole.
            var next = entries
            var structural = false
            if let removed = envelope.removed, !removed.isEmpty {
                let gone = Set(removed)
                next.removeAll { gone.contains($0.id) }
                structural = true
            }
            let after = envelope.after ?? []
            for (offset, row) in rows.enumerated() {
                let anchor = offset < after.count ? after[offset] : nil
                if let index = next.firstIndex(where: { $0.id == row.id }) {
                    let before = index > 0 ? next[index - 1].id : ""
                    if anchor == nil || anchor == before { next[index] = row; continue }
                    next.remove(at: index)
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
            whole = structural
            if structural { kept = next }
            entries = next
        } else {
            whole = true
            carryDisplayIDs(from: entries, to: rows)
            entries = rows
            generation = envelope.generation ?? generation
        }
        revision = envelope.revision ?? revision
        hasEarlier = envelope.more ?? false
        if envelope.entries?.contains(where: { $0.role == .user }) == true { error = nil }
        loaded = true
        keep?(whole, kept, SyncState(revision: revision, generation: generation))
        settleSending()
    }

    /// Drops an outgoing message once the transcript has moved past when
    /// it was sent and carries an identical message: it is on the record.
    func settleSending() {
        guard !sending.isEmpty else { return }
        func matched(_ text: String, _ recorded: String) -> Bool {
            recorded == text || recorded.hasPrefix(text + "\n\nAttached ") || (text.isEmpty && recorded.hasPrefix("Attached "))
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
    /// What a terminal session's shell has shown, base64 a chunk, for a
    /// terminal view that attaches later; and the view attached now, told
    /// each chunk and whether it replaces everything before it (a replay
    /// of the whole screen, sent when this window takes the terminal or
    /// subscribes again).
    public private(set) var terminalBacklog: [String] = []
    public var onTerminalBytes: ((_ chunk: String, _ startsOver: Bool) -> Void)?

    public init() {}

    /// The newest status label, and the wait before it is shown.
    private var latestActivity: String?
    private var activityFlush: Task<Void, Never>?
    /// Everything streamed as status this turn that is not part of the
    /// record — the tool calls, subagents, shells and thinking as they
    /// were announced — in order, for the footer under the thread. Cleared
    /// when the turn ends: the record's rows carry what was done.
    public var turnStatus: [StatusItem] = [] { didSet { changed() } }

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
            notice = envelope.notice
        case "earlier":
            // Rows from before the first one shown, put in front of it.
            let older = (envelope.entries ?? []).filter { row in !entries.contains { $0.id == row.id } }
            entries = older + entries
            hasEarlier = envelope.more ?? false
            keepEarlier?(older)
        case "ephemeral":
            // Everything that is not the record, on subscribing.
            turnStatus = envelope.status ?? []
            activity = envelope.activity
            latestActivity = envelope.activity
            busy = envelope.busy ?? false
            pendingApproval = envelope.approval
            notice = envelope.notice
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
            notice = envelope.notice
        case "approval":
            pendingApproval = envelope.approval
        case "tty":
            // A replay of the whole screen (its size set) stands in for
            // what was kept, even an empty one; a live chunk is appended.
            let replay = envelope.cols != nil
            guard let data = envelope.data, !data.isEmpty || replay else { return }
            if replay { terminalBacklog = [] }
            terminalBacklog.append(data)
            if terminalBacklog.count > 400 { terminalBacklog.removeFirst(terminalBacklog.count - 400) }
            onTerminalBytes?(data, replay)
        default:
            break
        }
    }
}
