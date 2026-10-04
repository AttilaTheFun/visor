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
public final class SessionRecord {
    public internal(set) var info: SessionInfo

    public internal(set) var entries: [TranscriptEntry] = [] {
        didSet {
            revision += 1
            stamp(from: oldValue)
            noteMarks(lookingBack: false)
            onRevision?()
        }
    }

    /// Counts up with every change to the rows; what a client syncing
    /// over HTTP compares to.
    public internal(set) var revision = 0

    /// Counts up when a client holding an older revision can no longer be
    /// brought up to date by a delta (the record of removed rows was let
    /// go): it takes the rows as a whole.
    /// Starts somewhere new with each run of the server, so a client that
    /// synced with an earlier run takes the rows as a whole.
    public internal(set) var generation = Int.random(in: 1...Int(Int32.max))

    /// The revision at which each row last changed or moved, so a client is
    /// given only the rows past the revision it holds.
    var rowSeq: [String: Int] = [:]

    /// Rows that went, and the revision they went at.
    var removedAt: [String: Int] = [:]

    /// How many removals are remembered before the record starts again.
    static let rememberedRemovals = 2000

    /// The turn's status lines so far — tool calls, subagents, shells,
    /// thinking — as announced, kept here so a client that subscribes
    /// mid-turn gets all of them. Cleared when the turn ends.
    var turn = TurnStatus()

    /// The slash commands the agent listed when it last ran here.
    var commands: [SlashCommand] = []

    var turnStatus: [StatusItem] { turn.items }

    /// The rows changed: whoever is waiting on a revision is answered.
    var onRevision: (() -> Void)?
    /// What is streaming, or has streamed and is not yet on the record:
    /// one entry per assistant message, in order, by message id. Each

    /// stays until a row with its id arrives from the file, so a message
    /// is never lost between the stream's end and the file's catching up.
    public internal(set) var streams: [(id: String, text: String)] = []

    /// The words of every stream, for anything that still wants one string.
    public var streaming: String { streams.map(\.text).joined(separator: "\n\n") }

    public internal(set) var activity: String?
    public internal(set) var error: String?
    /// Not a `let`: a session whose folder moved is given a new agent,
    /// because the directory is fixed when the process spawns.
    var process: AgentProcess

    /// The agent's events being handed to the server, one at a time and in
    /// the order the agent gave them.
    var listening: Task<Void, Never>?
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
    var indexer: SessionIndexer?
    /// Finding the file, then hearing what the indexer says of it.
    var following: Task<Void, Never>?
    /// Whether the cache holds rows before the first one here.
    var moreBefore = false

    /// How many times the file has been read in: what a test waits on.
    var fileLoads = 0

    /// The lines of the file the conversation holds, by uuid: what a new
    /// line must follow to be part of it rather than of a branch beside it.
    /// The prompts shown, in order, on the branch the chat follows. When
    /// the file is read again and the last of them is on an abandoned
    /// branch, the session was forked elsewhere and the chat moved to
    /// the newer branch — which the user is told, since nothing else
    /// would say why messages went away.
    var shownPrompts: [String] = []

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
    /// What a terminal session's shell drew, for the one client it is
    /// drawn for.
    var onTerminalBytes: ((Envelope) -> Void)?
    /// Whether the shell's program is drawing full-screen.
    var altScreen = false

    /// What the shell has shown, kept for a window that attaches next.
    var scrollback = Data()

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

    /// How many prompts are remembered as shown: enough to count what a
    /// fork left behind.
    static let rememberedPrompts = 200

    /// Words sent to an agent that writes its own log, which the log has
    /// not written yet: kept here, not as rows — the transcript is the log.
    /// Each with how many of the log's user rows had the same words when
    /// it was sent, so the same words sent again are told apart.
    var unwritten: [(text: String, seen: Int)] = []

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

    /// Everything that is not the record, in one piece.
    var ephemeralEnvelope: Envelope {
        .ephemeral(session: info.id, streams: streams.filter { !carries(messageID: $0.id) }.map { StreamChunk(id: $0.id, text: $0.text) }, status: turnStatus,
                   activity: activity, busy: info.busy, approval: info.pendingApproval, queued: info.queued, notice: notice)
    }
}
