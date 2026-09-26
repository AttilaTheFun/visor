// One computer: its saved address and password, the WebSocket to its menu
// bar app (through the host's socket service, so the same code runs in a
// browser), the sessions it lists, and a transcript per session the UI
// observes. Reconnects with a short backoff while the app is open. No
// Combine: observation is SwiftUI's, waiting is async/await.

import SwiftUI
import MessageCache
import VisorProtocol
import VisorServices

public struct HostConfig: Identifiable, Hashable, Sendable {
    public var id: String
    /// What the sidebar calls it (the host name once known).
    public var name: String
    /// The Mac's Tailscale name (its Serve endpoint): always wss:// on 443.
    public var host: String
    public var password: String
    /// Whether this computer has answered a login before (the sidebar's
    /// yellow "was reachable" badge rather than red "never").
    public var everConnected: Bool
    /// Which road reaches it (`Backends`); "tailscale" unless a fork says.
    public var backend: String

    public init(id: String = HostConfig.newID(), name: String, host: String, password: String, everConnected: Bool = false,
                backend: String = "tailscale") {
        self.id = id
        self.name = name
        self.host = host
        self.password = password
        self.everConnected = everConnected
        self.backend = backend
    }

    /// A random id without Foundation's UUID.
    /// This device, as the computers know it: kept, so a computer can
    /// tell whose window a terminal is drawn for across launches.
    public static let clientID: String = {
        if let saved = VisorHost.settings?.get(key: "clientID"), !saved.isEmpty { return saved }
        let fresh = newID()
        VisorHost.settings?.set(key: "clientID", value: fresh)
        return fresh
    }()

    public static func newID() -> String {
        (0..<24).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "host": .string(host), "password": .string(password),
                 "everConnected": .bool(everConnected), "backend": .string(backend)])
    }

    init?(json: JSONValue) {
        guard let id = json["id"].string, let host = json["host"].string else { return nil }
        self.init(id: id, name: json["name"].string ?? "", host: host, password: json["password"].string ?? "",
                  everConnected: json["everConnected"].bool ?? false, backend: json["backend"].string ?? "tailscale")
    }
}

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
    public nonisolated(unsafe) static var frame: UInt64 = 500_000_000
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
        Task { @MainActor [weak self] in
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
        entry.role.rawValue + "|" + HostConnection.trimmed(entry.text)
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
    }
    public var sending: [Outgoing] = [] { didSet { changed() } }

    /// Takes the record's rows as synced: the truth, replacing what was
    /// held; the outgoing messages it now carries go.
    /// The generation of the rows held; a different one in an answer means
    /// the rows were rebuilt and the answer is the whole, not a delta.
    public var generation = -1
    /// Told what a sync brought — the whole, or rows new or changed — so
    /// the cache keeps it. Set by the connection that owns this.
    var keep: ((_ whole: Bool, _ rows: [TranscriptEntry], _ state: SyncState) -> Void)?
    /// Told rows that came from before the first shown.
    var keepEarlier: (([TranscriptEntry]) -> Void)?

    func sync(_ envelope: Envelope) {
        let rows = envelope.entries ?? []
        let whole: Bool
        var kept = rows
        if let generation = envelope.generation, generation == self.generation, loaded {
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
                  let row = entries.last(where: { $0.role == .user && matched(out.entry.text, $0.text) }) else { return false }
            // The record's row is this message: shown under its id.
            if displayIDs[row.id] == nil { displayIDs[row.id] = out.id }
            return true
        }
    }
    /// What the terminal has shown, base64 a chunk, for a terminal view
    /// that attaches later; and the view attached now, told each chunk.
    public private(set) var terminalBacklog: [String] = []
    public var onTerminalBytes: ((String) -> Void)?

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
        activityFlush = Task { @MainActor [weak self] in
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
            guard let data = envelope.data, !data.isEmpty else { return }
            // A replay of the whole screen (cols set) stands in for what
            // was kept; a live chunk is appended.
            if envelope.cols != nil { terminalBacklog = [] }
            terminalBacklog.append(data)
            if terminalBacklog.count > 400 { terminalBacklog.removeFirst(terminalBacklog.count - 400) }
            onTerminalBytes?(data)
        default:
            break
        }
    }
}

@MainActor
public final class HostConnection: ObservableObject, Identifiable {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        /// Reached before, unreachable now (the socket dropped or never opened).
        case offline(String)
        /// The host answered and refused (a wrong password) or errs.
        case failed(String)
        /// The host does not know this device as its owner's and wants
        /// the password from its menu bar app (or the one saved is wrong).
        case needsPassword

        public var label: String {
            switch self {
            case .disconnected: "Not connected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .offline(let reason): "Offline: \(reason)"
            case .failed(let message): "Error: \(message)"
            case .needsPassword: "Needs a password"
            }
        }

        public var isError: Bool { if case .failed = self { true } else { false } }
        public var wantsPassword: Bool { if case .needsPassword = self { true } else { false } }
    }

    /// The sidebar badge: green connected; yellow reachable before, not
    /// now; red never reached, or the last attempt answered with an error.
    public enum Badge { case connected, wasConnected, unreachable }
    public var badge: Badge {
        switch state {
        case .connected: return .connected
        case .failed, .needsPassword: return .unreachable
        default: return config.everConnected ? .wasConnected : .unreachable
        }
    }

    @Published public var config: HostConfig {
        didSet { onConfigChange?() }
    }
    @Published public private(set) var state: State = .disconnected
    @Published public private(set) var sessions: [SessionInfo] = []
    @Published public private(set) var transcripts: [String: SessionTranscript] = [:]
    /// Each provider's models, from the host.
    @Published public private(set) var catalogs: [AgentCatalog] = []
    /// The store saves when the address or password changes.
    var onConfigChange: (() -> Void)?
    /// What `hello` gave for the socket's login, this connection.
    private var token: String?

    public nonisolated var id: String { configID }
    private nonisolated let configID: String
    /// Bumped whenever the live channel is closed, so a closed channel's
    /// late events are ignored.
    private var generation = 0
    /// The road to this computer, from its backend.
    private let transport: any HostTransport
    private var wantsConnection = false
    private var attempt = 0
    private var pendingSubscriptions: Set<String> = []

    public init(config: HostConfig) {
        self.transport = Backends.transport(for: config)
        self.config = config
        self.configID = config.id
        loadProjects()
        loadCachedSessions()
    }

    /// Always TLS on 443: the Mac's Tailscale Serve endpoint in front of the
    /// menu bar app — the WebSocket at its root, the REST API under /api.
    public var url: String { "wss://\(config.host)" }
    public var apiURL: String { "https://\(config.host)/api" }
    /// The last command that failed, for the UI.
    @Published public var commandError: String?

    public enum HostError: Error { case noHTTP }

    /// One REST call, returning the answer's body.
    public func fetch(_ method: String, _ path: String, _ body: Envelope? = nil) async throws -> Envelope {
        let text = try await transport.call(method, path, body: body?.encoded() ?? "", config: config)
        return Envelope.decode(text, defaultType: "reply") ?? Envelope(type: "reply")
    }

    /// The host's subfolders of `path` (the picker); the resolved path comes back too.
    public func folders(at path: String) async throws -> (path: String, folders: [String]) {
        let reply = try await fetch("GET", "/folders?path=" + HostConnection.escape(path))
        return (reply.path ?? path, reply.folders ?? [])
    }

    /// Whether the folder is still on the computer (a project whose folder
    /// was renamed or moved answers false).
    public func folderExists(_ path: String) async throws -> Bool {
        let reply = try await fetch("GET", "/folders?path=" + HostConnection.escape(path))
        return reply.exists ?? true
    }

    /// The bytes of a picture the computer holds, base64 (the REST side
    /// speaks JSON, so they travel as text).
    public func fileData(path: String) async throws -> String {
        let reply = try await fetch("GET", "/file?path=" + HostConnection.escape(path))
        guard let data = reply.text, !data.isEmpty else { throw HostError.noHTTP }
        return data
    }

    /// Puts a picture or a video on the computer and returns where it landed, which
    /// is what the agent is then pointed at.
    public func upload(base64: String, name: String) async throws -> String {
        var body = Envelope(type: "file")
        body.text = base64
        body.title = name
        let reply = try await fetch("POST", "/file", body)
        guard let path = reply.path, !path.isEmpty else { throw HostError.noHTTP }
        return path
    }

    /// Creates the folder (and its parents) on the host.
    public func makeFolder(_ path: String) async throws -> String {
        var body = Envelope(type: "mkdir"); body.path = path
        let reply = try await fetch("POST", "/folders", body)
        return reply.path ?? path
    }

    /// The agent's own sessions started in `cwd`, newest first.
    public func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] {
        let reply = try await fetch("GET", "/resumable?agent=\(agent.rawValue)&cwd=" + HostConnection.escape(cwd))
        return reply.resumable ?? []
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95 || byte == 126 || byte == 47 {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(2)
            }
        }
        return out
    }

    /// One REST call; the answer's `sessions` refreshes the list at once
    /// (the socket's broadcast follows for everyone else).
    private func api(_ method: String, _ path: String, _ body: Envelope? = nil, then: (() -> Void)? = nil) {
        let payload = body?.encoded() ?? ""
        let config = config
        let transport = transport
        Task { [weak self] in
            do {
                let text = try await transport.call(method, path, body: payload, config: config)
                guard let self else { return }
                if let reply = Envelope.decode(text, defaultType: "reply"), let list = reply.sessions {
                    if reply.type == "welcome" || method == "DELETE" {
                        self.sessions = list
                    } else {
                        for info in list {
                            if let index = self.sessions.firstIndex(where: { $0.id == info.id }) { self.sessions[index] = info } else { self.sessions.append(info) }
                        }
                    }
                }
                self.commandError = nil
                then?()
            } catch {
                self?.commandError = "\(error)"
            }
        }
    }

    /// Edits the saved address or password (the store saves through `onConfigChange`).
    public func update(_ change: (inout HostConfig) -> Void) {
        var next = config
        change(&next)
        config = next
    }

    public func connect() {
        wantsConnection = true
        attempt = 0
        open()
    }

    public func disconnect() {
        wantsConnection = false
        closeSocket()
        state = .disconnected
        sessions = []
    }

    private func closeSocket() {
        generation += 1
        transport.disconnect()
    }

    /// First `hello` over HTTP — the computer lets this device in on the
    /// network's word (its owner's device) or on the password, and hands
    /// back its name and a token — then the socket, logged in with the
    /// token. A 401 is the computer asking for a password: no retrying
    /// until one is saved.
    private func open() {
        guard wantsConnection else { return }
        closeSocket()
        state = .connecting
        let mine = generation
        let transport = transport
        let config = config
        Task { [weak self] in
            do {
                let text = try await transport.call("GET", "/hello", body: "", config: config)
                guard let self, self.generation == mine, self.wantsConnection else { return }
                let hello = Envelope.decode(text, defaultType: "hello")
                self.token = hello?.token
                if let host = hello?.host, !host.isEmpty, host != self.config.name { self.config.name = host }
                self.openSocket(mine)
            } catch {
                guard let self, self.generation == mine, self.wantsConnection else { return }
                if transport.status(of: error) == 401 {
                    self.wantsConnection = false
                    self.state = .needsPassword
                } else {
                    self.dropped("\(error)")
                }
            }
        }
    }

    private func openSocket(_ mine: Int) {
        transport.connect(config) { [weak self] event in
            // A channel closed and reopened since: what the old one says
            // is no longer ours.
            guard let self, self.generation == mine else { return }
            switch event {
            case .opened: self.send(.login(password: self.config.password, token: self.token, client: HostConfig.clientID))
            case .message(let text): self.handle(text)
            case .closed(let reason): self.dropped(reason)
            }
        }
    }


    private func dropped(_ reason: String) {
        generation += 1
        transport.disconnect()
        if case .failed = state {} else { state = wantsConnection ? .offline(reason) : .disconnected }
        for transcript in transcripts.values { transcript.busy = false; transcript.activity = nil }
        guard wantsConnection else { return }
        attempt += 1
        let delay = min(30, 1 << min(attempt, 5))
        let mine = generation
        Task { [weak self] in
            await self?.transport.delay(milliseconds: Int32(delay * 1000))
            guard let self, self.wantsConnection, self.generation == mine else { return }
            self.open()
        }
    }

    private func handle(_ text: String) {
        guard let envelope = Envelope.decode(text) else { return }
        switch envelope.type {
        case "welcome":
            state = .connected
            attempt = 0
            if let host = envelope.host, !host.isEmpty { config.name = host }
            if !config.everConnected { config.everConnected = true }
            sessions = envelope.sessions ?? []
            saveCachedSessions()
            catalogs = envelope.catalogs ?? []
            // Re-subscribe to whatever was open before the drop.
            for id in pendingSubscriptions.union(transcripts.keys) { send(.subscribe(session: id)) }
            pendingSubscriptions.removeAll()
            // A folder may have been renamed or moved while we were away.
            Task { await refreshMissing() }
        case "catalogs":
            catalogs = envelope.catalogs ?? []
        case "error":
            if envelope.message == "Wrong password" {
                wantsConnection = false
                state = .needsPassword
            } else {
                state = .failed(envelope.message ?? "Rejected")
            }
        case "sessions":
            sessions = envelope.sessions ?? []
            saveCachedSessions()
            // Words sent while the agent was busy come back in its queue.
            for session in sessions { transcripts[session.id]?.settleSending() }
        default:
            guard let id = envelope.session else { return }
            transcript(for: id).apply(envelope)
        }
    }

    /// The rows already seen, by host and session: on disk where there
    /// is SQLite, so a session opens as it was last seen and syncs only
    /// what changed since; in memory on the web.
    nonisolated(unsafe) static var cache: MessageCache = .open(named: "messages")
    private func cacheKey(_ sessionID: String) -> String { id + "/" + sessionID }

    public func transcript(for sessionID: String) -> SessionTranscript {
        if let existing = transcripts[sessionID] { return existing }
        let transcript = SessionTranscript()
        let key = cacheKey(sessionID)
        // As last seen, at once; the sync then asks only for what moved.
        let kept = Self.cache.messages(in: key, limit: 600)
        if !kept.messages.isEmpty, let state = Self.cache.syncState(of: key) {
            transcript.entries = kept.messages
            transcript.hasEarlier = kept.more
            transcript.revision = state.revision
            transcript.generation = state.generation
            transcript.loaded = true
        }
        transcript.keep = { whole, rows, state in
            if whole { try? Self.cache.replace(key, with: rows) } else { try? Self.cache.append(key, rows) }
            try? Self.cache.setSyncState(state, for: key)
        }
        transcript.keepEarlier = { rows in try? Self.cache.prepend(key, rows) }
        transcripts[sessionID] = transcript
        startSyncing(sessionID, transcript)
        return transcript
    }

    /// The transcript syncs over HTTP, apart from the socket: each request
    /// names the revision held and is answered when the rows have moved
    /// past it (or after a while, with the same), and the answer replaces
    /// the rows held — so a dropped socket message, a sleep, a restart of
    /// the computer's server all heal on the next answer. Runs for as long
    /// as the transcript is kept.
    private var syncing: [String: Task<Void, Never>] = [:]

    private func startSyncing(_ sessionID: String, _ transcript: SessionTranscript) {
        guard syncing[sessionID] == nil else { return }
        let transport = transport
        syncing[sessionID] = Task { [weak self, weak transcript] in
            while !Task.isCancelled {
                guard let self, let transcript else { return }
                let config = self.config
                let revision = transcript.revision
                do {
                    let text = try await transport.call("GET", "/sessions/\(sessionID)/transcript?since=\(revision)&generation=\(transcript.generation)", body: "", config: config)
                    guard let envelope = Envelope.decode(text, defaultType: "transcript") else { continue }
                    if (envelope.revision ?? -1) != revision || !transcript.loaded { transcript.sync(envelope) }
                } catch {
                    // The computer is away, or a hold timed out on the way:
                    // ask again shortly.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    /// Opens a session's transcript: replays it, then streams.
    public func subscribe(_ sessionID: String) {
        _ = transcript(for: sessionID)
        if state == .connected { send(.subscribe(session: sessionID)) } else { pendingSubscriptions.insert(sessionID) }
    }

    public func start(agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String? = nil) -> String {
        let id = HostConfig.newID()
        let transcript = transcript(for: id)
        transcript.loaded = true
        // Subscribe once the host has the session (the stream is the socket's).
        api("POST", "/sessions", .start(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions,
                                        resume: resume)) { [weak self] in
            self?.subscribe(id)
        }
        return id
    }

    /// Takes the session into the agent's own terminal, drawn for a
    /// window of this size on this client. Any other client's terminal
    /// ends: it is one interface, at one size, for one window.
    public func assumeControl(_ sessionID: String, cols: Int, rows: Int) {
        send(.assumeControl(session: sessionID, cols: cols, rows: rows))
    }

    /// The user has read what the session had to tell them.
    public func acknowledge(_ sessionID: String) {
        transcript(for: sessionID).notice = nil
        send(.acknowledge(session: sessionID))
    }

    /// Hands the session back to the chat, which every client can draw.
    public func returnToChat(_ sessionID: String) {
        send(.returnToChat(session: sessionID))
    }

    /// Whether the terminal of this session is drawn for this client.
    public func controlsTerminal(_ session: SessionInfo) -> Bool {
        session.mode.controlled(by: HostConfig.clientID)
    }

    /// Asks for the rows before the first one the transcript has.
    public func loadEarlier(_ sessionID: String) {
        guard let first = transcript(for: sessionID).entries.first else { return }
        send(.earlier(session: sessionID, before: first.id))
    }

    /// What the user typed into the terminal, base64.
    public func sendInput(_ sessionID: String, data: String) {
        send(.input(session: sessionID, data: data))
    }

    public func resize(_ sessionID: String, cols: Int, rows: Int) {
        send(.resize(session: sessionID, cols: cols, rows: rows))
    }

    // MARK: Projects

    /// A folder on the host and the sessions running in it.
    public struct Project: Identifiable, Hashable {
        public var cwd: String
        public var sessions: [SessionInfo]
        /// Ended sessions kept in this folder: they can come back or go.
        public var archived: [SessionInfo] = []
        /// What the user calls this folder, if not its own name. Kept on
        /// this device against the folder's path, so it follows the
        /// project rather than any one session.
        public var alias: String?
        /// The folder was renamed or moved out from under us: the computer
        /// says there is nothing there now.
        public var missing = false
        /// Nothing left here, so the folder can be forgotten.
        public var isEmpty: Bool { sessions.isEmpty && archived.isEmpty }

        public init(cwd: String, sessions: [SessionInfo], archived: [SessionInfo] = [],
                    alias: String? = nil, missing: Bool = false) {
            self.cwd = cwd
            self.sessions = sessions
            self.archived = archived
            self.alias = alias
            self.missing = missing
        }
        public var id: String { cwd }
        /// The folder's own name on disk.
        public var folderName: String {
            let path = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
            if path == "~" || path.isEmpty { return "Home" }
            return path.split(separator: "/").last.map(String.init) ?? path
        }
        /// What to show: the alias when there is one.
        public var name: String {
            if let alias, !alias.isEmpty { return alias }
            return folderName
        }
    }

    /// Folders the user added without a session yet (kept on this device).
    @Published public private(set) var knownProjects: [String] = []
    /// The names the user gave folders, by path (this device only).
    @Published public private(set) var projectAliases: [String: String] = [:]
    /// Folders the computer says are no longer there.
    @Published public private(set) var missingProjects: Set<String> = []

    /// The computer's projects: every known folder and every folder with a
    /// live session, in the order they were added.
    public var projects: [Project] {
        var order: [String] = knownProjects
        for session in sessions where !order.contains(session.cwd) { order.append(session.cwd) }
        return order.map { cwd in
            Project(cwd: cwd,
                    sessions: activeSessions.filter { $0.cwd == cwd },
                    archived: archivedSessions.filter { $0.cwd == cwd },
                    alias: projectAliases[cwd],
                    missing: missingProjects.contains(cwd))
        }
    }

    /// Without the whitespace around it. wasm's Foundation has no
    /// trimmingCharacters; the client builds for the browser too.
    static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace || first.isNewline { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace || last.isNewline { slice = slice.dropLast() }
        return String(slice)
    }

    /// Names a project. An empty name gives the folder its own name back.
    public func renameProject(_ cwd: String, to name: String) {
        let trimmed = Self.trimmed(name)
        if trimmed.isEmpty { projectAliases.removeValue(forKey: cwd) } else { projectAliases[cwd] = trimmed }
        saveProjects()
    }

    /// Points a project at the folder it moved to: the alias follows it,
    /// and the computer moves the sessions that ran there.
    public func relocateProject(_ cwd: String, to destination: String) {
        let alias = projectAliases[cwd]
        projectAliases.removeValue(forKey: cwd)
        if let alias { projectAliases[destination] = alias }
        if let index = knownProjects.firstIndex(of: cwd) { knownProjects[index] = destination }
        else if !knownProjects.contains(destination) { knownProjects.append(destination) }
        missingProjects.remove(cwd)
        saveProjects()
        var e = Envelope(type: "relocate")
        e.path = cwd
        e.cwd = destination
        api("POST", "/relocate", e)
        Task { await refreshMissing() }
    }

    /// Forgets a project and every session in it.
    public func removeProjectAndSessions(_ cwd: String) {
        for session in sessions where session.cwd == cwd { end(session.id) }
        removeProject(cwd)
    }

    /// Asks the computer which of our folders are still there. Cheap (one
    /// question per project) and only worth doing when connected.
    public func refreshMissing() async {
        guard state == .connected else { return }
        var gone: Set<String> = []
        for cwd in Set(projects.map(\.cwd)) {
            guard let there = try? await folderExists(cwd) else { continue }
            if !there { gone.insert(cwd) }
        }
        missingProjects = gone
    }

    public func addProject(_ cwd: String) {
        guard !knownProjects.contains(cwd) else { return }
        knownProjects.append(cwd)
        saveProjects()
    }

    public func removeProject(_ cwd: String) {
        knownProjects.removeAll { $0 == cwd }
        projectAliases.removeValue(forKey: cwd)
        missingProjects.remove(cwd)
        saveProjects()
    }

    /// What was listed last time. Shown while the connection is being
    /// made, so relaunching does not empty the sidebar and fill it again
    /// a second later. Every session reads as not-connected until the
    /// computer answers, which is what the yellow dot says.
    func loadCachedSessions() {
        let saved = VisorHost.settings?.get(key: "sessions." + id) ?? ""
        guard !saved.isEmpty, let list = parseJSON(saved)?.array?.compactMap(SessionInfo.init(json:)) else { return }
        sessions = list.map { info in
            var quiet = info
            // Nothing can be running: we are not even connected yet.
            quiet.busy = false
            quiet.pendingApproval = nil
            return quiet
        }
    }

    private func saveCachedSessions() {
        VisorHost.settings?.set(key: "sessions." + id, value: JSONValue.array(sessions.map(\.json)).encoded())
    }

    func loadProjects() {
        let saved = VisorHost.settings?.get(key: "projects." + id) ?? ""
        knownProjects = parseJSON(saved)?.array?.compactMap(\.string) ?? []
        let names = VisorHost.settings?.get(key: "projectNames." + id) ?? ""
        var aliases: [String: String] = [:]
        for entry in parseJSON(names)?.array ?? [] {
            guard let cwd = entry["cwd"].string, let name = entry["name"].string else { continue }
            aliases[cwd] = name
        }
        projectAliases = aliases
    }

    private func saveProjects() {
        VisorHost.settings?.set(key: "projects." + id, value: JSONValue.array(knownProjects.map(JSONValue.string)).encoded())
        let names = projectAliases.keys.sorted().map { cwd in
            JSONValue.object(["cwd": .string(cwd), "name": .string(projectAliases[cwd] ?? "")])
        }
        VisorHost.settings?.set(key: "projectNames." + id, value: JSONValue.array(names).encoded())
    }

    public func sendMessage(_ sessionID: String, text: String, images: [String] = []) {
        // On screen before it is on the record: the last row, and it stays
        // last until the transcript syncs an identical message sent after
        // this one — never removed by a sync from before it was received.
        // Without the whitespace around it, which is how the record keeps
        // it (and a phone's keyboard leaves a space after the last word).
        let text = Self.trimmed(text)
        let session = transcript(for: sessionID)
        let entry = TranscriptEntry(id: "sending-" + HostConfig.newID(), role: .user, text: text, images: images)
        defer { session.flush() }
        session.sending.append(SessionTranscript.Outgoing(id: entry.id, entry: entry, sinceRevision: session.revision))
        api("POST", "/sessions/\(sessionID)/send", .send(session: sessionID, text: text, images: images))
    }

    public func stop(_ sessionID: String) { api("POST", "/sessions/\(sessionID)/stop") }

    /// Drops a message that is waiting for the turn to end — one of them,
    /// or all of them when `text` is nil.
    public func unqueue(_ sessionID: String, text: String? = nil) {
        var e = Envelope(type: "unqueue")
        e.session = sessionID
        e.text = text
        api("POST", "/sessions/\(sessionID)/unqueue", e)
    }

    public func setPermissions(_ sessionID: String, skip: Bool) {
        api("POST", "/sessions/\(sessionID)/permissions", .permissions(session: sessionID, skipPermissions: skip))
    }

    public func setSettings(_ sessionID: String, model: String?, effort: String?) {
        api("POST", "/sessions/\(sessionID)/settings", .settings(session: sessionID, model: model, effort: effort))
    }

    public func catalog(for agent: AgentKind) -> AgentCatalog? { catalogs.first { $0.agent == agent } }

    /// What to call a session's model in the composer's pill.
    public func modelTitle(for session: SessionInfo) -> String {
        // The chosen model names the session; with no choice, the one a
        // turn actually ran on; else the agent's default.
        let named = session.model ?? session.reportedModel
        return catalog(for: session.agent)?.title(for: named)
            ?? named.map(AgentCatalog.prettyModelName)
            ?? session.agent.title
    }

    public func approve(_ sessionID: String, id: String, allow: Bool) {
        api("POST", "/sessions/\(sessionID)/approve", .approve(session: sessionID, id: id, allow: allow))
    }

    public func rename(_ sessionID: String, title: String) {
        api("POST", "/sessions/\(sessionID)/rename", .rename(session: sessionID, title: title))
    }

    public func archive(_ sessionID: String) { api("POST", "/sessions/\(sessionID)/archive") }

    public func unarchive(_ sessionID: String) { api("POST", "/sessions/\(sessionID)/unarchive") }

    public var activeSessions: [SessionInfo] { sessions.filter { !$0.archived } }
    public var archivedSessions: [SessionInfo] { sessions.filter(\.archived) }

    public func end(_ sessionID: String) {
        api("DELETE", "/sessions/\(sessionID)")
        transcripts.removeValue(forKey: sessionID)
        syncing.removeValue(forKey: sessionID)?.cancel()
        try? Self.cache.remove(cacheKey(sessionID))
    }

    private func send(_ envelope: Envelope) {
        transport.send(envelope.encoded())
    }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
