// The server: a WebSocket listener and a small HTTP one, both on loopback
// (the road in from the network is the exposure's front on 443), a
// password or the road's word on each caller, and the protocol's
// envelopes routed to the sessions (SessionRecord.swift), each of which
// is one agent. Sessions are written down and outlive the app.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

/// The server's message cache: every session's rows, from the agents' own
/// files where they have one and from their events where they do not.
/// Tests point `shared` at a cache of their own.
@MainActor
public enum ServerCache {
    public static var shared: MessageCache = .open(named: "messages")
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
    /// The files beside each queued message (`info.queued`).
    var queuedImages: [[String]]?
    static let currentShape = 2

    init(info: SessionInfo, entries: [TranscriptEntry], resumeID: String?, shape: Int?,
         interrupted: Bool? = nil, agentPID: Int32? = nil, shownPrompts: [String]? = nil, notice: String? = nil,
         queuedImages: [[String]]? = nil) {
        self.info = info
        self.entries = entries
        self.resumeID = resumeID
        self.shape = shape
        self.interrupted = interrupted
        self.agentPID = agentPID
        self.shownPrompts = shownPrompts
        self.notice = notice
        self.queuedImages = queuedImages
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
        queuedImages = try c.decodeIfPresent([[String]].self, forKey: .queuedImages)
    }
}

@MainActor
public final class VisorServer: ObservableObject {
    /// The one server of the menu bar app.
    public static let shared = VisorServer()

    @Published public internal(set) var sessions: [SessionRecord] = []
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
            Self.secrets.set("password", password)
            if listener == nil, !password.isEmpty { start() }
        }
    }
    /// Where the password is kept: the keychain; tests swap in their own.
    static var secrets: SecretStore = KeychainSecrets()
    /// The bundle ids this app had before, whose settings it takes over.
    static let formerBundleIDs = ["com.LoganShire.Visor.MenuBar"]

    /// The folder an earlier build kept its cache in (Application Support,
    /// by bundle id), taken over the first time this build runs.
    private static func adoptFormerFolders() {
        guard storeRoot == nil, let current = Bundle.main.bundleIdentifier, !formerBundleIDs.contains(current) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = base.appendingPathComponent(current)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        for former in formerBundleIDs {
            let source = base.appendingPathComponent(former)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: target)
                return
            }
        }
    }

    /// The password as kept — the keychain — or, the first time, as an
    /// earlier build kept it (in its settings), moved into the keychain.
    private static func keptPassword() -> String {
        if let kept = secrets.get("password"), !kept.isEmpty { return kept }
        let earlier = [UserDefaults.standard] + formerBundleIDs.compactMap { UserDefaults(suiteName: $0) }
        for defaults in earlier {
            if let old = defaults.string(forKey: "visor.password"), !old.isEmpty {
                secrets.set("password", old)
                for place in earlier { place.removeObject(forKey: "visor.password") }
                return old
            }
        }
        return ""
    }
    /// The network user this Mac belongs to, as the exposure reports it;
    /// requests the road names as theirs need no password.
    @Published public private(set) var hostLogin: String?
    /// This Mac's name on the network ("my-mac.tail1234.ts.net"), once the
    /// exposure has said it; learned with the owner, so the menu shows it
    /// even when Tailscale came up after the app did.
    @Published public private(set) var address: String?
    /// What went wrong putting the front in place, or nil.
    @Published public private(set) var serveError: String?
    /// The other computers' servers this one's agents reach (Links.swift).
    @Published public internal(set) var links: [ConnectionCode] = []
    /// The slash commands each agent listed when it last ran (Commands.swift).
    var knownCommands: [AgentKind: [SlashCommand]] = [:]
    /// The devices that asked for pushes, what each session last looked like,
    /// and what sends them (PushNotifications.swift).
    var pushDevices: [PushDevice] = VisorServer.keptPushDevices()
    var pushStates: [String: PushState] = [:]
    let apnsSender = APNsSender()
    /// Told each push as it is decided, before anything is sent (tests).
    var onPush: ((_ title: String, _ body: String, _ session: String, _ kind: String) -> Void)?
    private var modelsRefresh: Task<Void, Never>?
    /// The `front()` under way; and how many have found Tailscale not ready.
    private var fronting: Task<Void, Never>?
    /// Asked for while an attempt ran: run again once it ends.
    private var frontAgain = false
    private var frontAttempts = 0
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
    let agentToken = UUID().uuidString
    /// Sessions this launch was asked to bring back into a running state:
    /// they were mid-turn when the app went away, and were named on the
    /// command line (or in VISOR_RESUME). Nudged once the listener is up.
    private var pendingResumes: [String] = []

    public init(port: UInt16 = Envelope.defaultPort) {
        self.port = port
        Self.adoptFormerFolders()
        password = Self.keptPassword()
        links = Self.keptLinks()
        loadSessions()
    }

    /// A server apart from the user's own: its own port, a folder of its
    /// own for what it keeps, the password given and held in memory, and
    /// no road from the network. For trying a build against real agents
    /// without touching the installed server's sessions, its keychain or
    /// its front (tools/staging_server).
    public static func staging(port: UInt16, root: URL, password: String) -> VisorServer {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeRoot = root
        secrets = MemorySecrets()
        ServerCache.shared = .inMemory()
        let server = VisorServer(port: port)
        server.exposure = NoExposure()
        server.password = password
        return server
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
        // The agent token too: the agents this server started (and the
        // tools they run, such as a deploy) hold it, and no one else.
        return bearer == password || tokens.contains(bearer) || bearer == agentToken
    }

    /// The answer to a request that is not let in. A request the road
    /// names a user for, while this Mac does not yet know its own user
    /// (Tailscale still starting at login), is told to come back rather
    /// than refused: a refusal reads as "wants a password", and a client
    /// stops trying.
    func refusal(_ request: HTTPRequest) -> HTTPResponse {
        if hostLogin == nil, exposure.requester(headers: request.headers) != nil {
            front()
            return HTTPResponse(503, "{\"error\":\"starting\"}")
        }
        return HTTPResponse(401, "{\"error\":\"wrong password\"}")
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
        guard !password.isEmpty, let address else { return nil }
        return ConnectionCode(name: hostName, host: address, password: password)
    }

    // MARK: Persistence

    /// ~/Library/Application Support/Visor/sessions.json (archive.json
    /// before sessions were all kept; read once and folded in).
    /// Tests point this at a scratch folder: a server built over the real
    /// archive ends the agents it records as orphans of a previous life.
    static var storeRoot: URL?
    static var storeURL: URL {
        let base = storeRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.json")
    }

    /// Beside the sessions: the slash commands each agent last listed.
    static var commandsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("commands.json") }

    /// Which sessions this launch carries on with. Whatever was running
    /// when the app went away comes back running — that is the default and
    /// needs no argument. The launch list only narrows it:
    ///     open -a "Visor Server" --args --resume-sessions <id>,<id>
    ///     VISOR_RESUME=none "…/Visor Server.app/Contents/MacOS/Visor Server"
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
        var orphans: [(session: String, pid: Int32, resume: String?)] = []
        for item in stored {
            var info = item.info
            info.busy = false
            info.ended = false
            // A terminal is drawn for a client that is no longer here.
            info.mode = .chat
            // An agent of ours that outlived the app (we were killed
            // outright, or quit before it went): it still holds the
            // session, so it goes before anything resumes into it.
            if let pid = item.agentPID { orphans.append((info.id, pid, item.resumeID)) }
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
            record.refreshResume()
            record.interrupted = item.interrupted ?? false
            // The outbox, lined up with its words (a file from before it was
            // kept has words and no files).
            let files = item.queuedImages ?? []
            record.queuedImages = info.queued.indices.map { $0 < files.count ? files[$0] : [] }
            record.primePreview()
            record.held = item.agentPID != nil
            sessions.append(record)
        }
        try? FileManager.default.removeItem(at: legacy)
        if !stored.isEmpty { saveArchive() }
        guard !orphans.isEmpty else { return }
        // Until its orphan is gone, what is said to a session waits.
        Task {
            for orphan in orphans {
                await Self.endOrphan(pid: orphan.pid, resume: orphan.resume)
                if let record = session(orphan.session) { release(record) }
            }
        }
    }

    /// Writes every session (the name is historical: it began as the archive).
    /// Ends an agent left over from a previous life of the app. The pid
    /// alone is not trusted — pids are reused — so the process must still
    /// look like the agent it claims to be.
    @concurrent
    static func endOrphan(pid: Int32, resume: String?) async {
        guard pid > 1, kill(pid, 0) == 0 else { return }
        guard let command = await Command.output("/bin/ps", ["-p", String(pid), "-o", "command="])?.text else { return }
        guard command.contains("claude") || command.contains("codex") || command.contains("openrouter") else { return }
        if let resume, !resume.isEmpty, !command.contains(resume) { return }
        kill(pid, SIGTERM)
        if await !Command.exited(pid, within: .seconds(2)) { kill(pid, SIGKILL) }
    }

    /// False once a store failed to decode: nothing is written until the
    /// app is restarted against a file it understands.
    private var storeIsReadable = true

    private func saveArchive() {
        guard storeIsReadable else { return }
        let stored = sessions.map(\.stored)
        do {
            let data = try JSONEncoder().encode(stored)
            // Yesterday's file is kept beside today's. It costs nothing and
            // it is the difference between a bad write and a lost afternoon.
            let backup = Self.storeURL.deletingLastPathComponent().appendingPathComponent("sessions.previous.json")
            if let existing = try? Data(contentsOf: Self.storeURL), existing.count > 2, existing != data {
                try? existing.write(to: backup, options: .atomic)
            }
            try data.write(to: Self.storeURL, options: .atomic)
            if savingFailed {
                savingFailed = false
                lastError = nil
            }
        } catch {
            // Said in the menu, not swallowed: sessions that are not being
            // written down are lost at the next quit.
            savingFailed = true
            lastError = "Sessions are not being saved: \(error.localizedDescription)"
        }
    }

    /// The last write of the sessions failed; cleared by the next that works.
    private var savingFailed = false

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
                rebuild(record)
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
                let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
        // An agent that has gone leaves a pipe that cannot be written to:
        // that is an error to the write, not a signal that ends the app.
        signal(SIGPIPE, SIG_IGN)
        // Where the agents' tools are, for those not in the usual places.
        let tools = backends.all.map(\.tool) + ["node"]
        Task {
            await ToolPath.locate(tools)
            broadcastCatalogs()
        }
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
            // The listener's queue is the main one: what it says is taken
            // as it is said, in order.
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listening = true; self?.lastError = nil
                    case .failed(let error): self?.listening = false; self?.lastError = "\(error)"
                    case .cancelled: self?.listening = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "\(error)"
        }
        front()
        keepModelsFresh()
        resumePending()
    }

    /// Asks the agents for their models now and every few hours (a new
    /// model, a changed plan), and tells the clients when a list changed.
    /// Again a few minutes after launch, and after an answer that dropped
    /// models: one given while the account was still being checked can be
    /// the base models alone.
    private func keepModelsFresh() {
        modelsRefresh?.cancel()
        modelsRefresh = Task {
            var soon = true
            while !Task.isCancelled {
                async let claude = ClaudeBackend.refreshModels()
                async let codex = CodexBackend.refreshModels()
                // OpenRouter's list, from its CLI, when it is a day old.
                async let openrouter = OpenRouterBackend.refreshIfStale()
                let answers = await (claude, codex, openrouter)
                if answers.0 == .changed || answers.1 == .changed || answers.2 { broadcastCatalogs() }
                let again: Duration = soon || answers.0 == .doubted ? .seconds(5 * 60) : .seconds(6 * 60 * 60)
                soon = false
                try? await Task.sleep(for: again)
            }
        }
    }

    /// The front on 443, put in place whenever it is not: there is no
    /// switch for it. What goes wrong is shown in the menu.
    /// At login the menu bar app and Tailscale start together, so the
    /// first try often finds Tailscale not yet up: no owner and no front.
    /// It tries again — every few seconds at first, then every minute —
    /// until both are known.
    public func front() {
        // One attempt at a time; one asked for meanwhile runs after it, as
        // it may know something the running one did not.
        guard fronting == nil else { frontAgain = true; return }
        let exposure = self.exposure
        let port = self.port
        guard exposure.installed else { serveError = "\(exposure.title) is not installed"; return }
        fronting = Task {
            var message: String?
            let identity = await exposure.identity()
            let address = await exposure.address()
            if identity == nil {
                message = "waiting for \(exposure.title)"
            } else if await !exposure.fronts(port: port) {
                let output = await exposure.front(port: port).lowercased()
                if output.contains("error") || output.contains("not enabled") || output.contains("not allowed") {
                    message = output.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? output
                }
            }
            fronting = nil
            if frontAgain {
                frontAgain = false
                front()
                return
            }
            if let identity { hostLogin = identity }
            if let address { self.address = address }
            serveError = message
            guard message != nil else { frontAttempts = 0; return }
            frontAttempts += 1
            let wait = frontAttempts < 24 ? 5 : 60
            Task {
                try? await Task.sleep(for: .seconds(wait))
                front()
            }
        }
    }

    /// Returns once the attempt under way, if there is one, has learned
    /// what it could (tests).
    func fronted() async { await fronting?.value }

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
        // What was waiting when the app went away goes now; behind a nudge
        // it waits for that turn to end, as any queued message does.
        for record in sessions where !record.info.archived && !record.info.queued.isEmpty && !record.info.busy {
            let waiting = record.takeQueue()
            deliver(waiting.text, to: record, images: waiting.images)
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
    private var transcriptWaiters: [String: [(revision: Int, generation: Int, respond: (HTTPResponse) -> Void)]] = [:]
    static let transcriptHold: TimeInterval = 25

    private func transcriptJSON(_ record: SessionRecord, since: Int?) -> HTTPResponse {
        .json(record.transcriptEnvelope(since: since).encoded())
    }

    /// Answers everyone waiting on this session's transcript with the
    /// rows changed since the revision each holds.
    private func answerTranscriptWaiters(for record: SessionRecord) {
        guard let waiting = transcriptWaiters.removeValue(forKey: record.info.id), !waiting.isEmpty else { return }
        // A delta while the generation holds; the whole if it moved on.
        for waiter in waiting {
            waiter.respond(transcriptJSON(record, since: waiter.generation == record.generation ? waiter.revision : nil))
        }
    }

    func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let path = (request.path.split(separator: "?").first.map(String.init) ?? request.path).replacingOccurrences(of: "/api", with: "", options: .anchored)
        let parts = path.split(separator: "/").map(String.init)
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "commands", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            var e = Envelope(type: "commands")
            e.session = record.info.id
            e.commands = commands(for: record)
            return respond(.json(e.encoded()))
        }
        if request.method == "GET", parts.count == 3, parts[0] == "sessions", parts[2] == "transcript", authorized(request) {
            guard let record = session(parts[1]) else { return respond(HTTPResponse(404, "{\"error\":\"no such session\"}")) }
            record.followFileIfNeeded()
            if record.onRevision == nil { record.onRevision = { [weak self, weak record] in
                guard let self, let record else { return }
                self.answerTranscriptWaiters(for: record)
            } }
            let query = Self.query(request.path)
            let had = (query["since"] ?? query["revision"]).flatMap(Int.init)
            // A delta only for a client of this generation; any other (a
            // first sync, a client from before a restart) gets the whole.
            // (A client that does not say its generation is taken to be
            // current, as before, rather than answered at once with the
            // whole over and over.)
            let current = query["generation"].flatMap(Int.init).map { $0 == record.generation } ?? true
            // Held only while the client has exactly what there is.
            guard current, had == record.revision else {
                return respond(transcriptJSON(record, since: current ? had.map { $0 > record.revision ? -1 : $0 } : nil))
            }
            transcriptWaiters[record.info.id, default: []].append((revision: record.revision, generation: record.generation, respond: respond))
            Task { [weak self, weak record] in
                try? await Task.sleep(for: .seconds(Self.transcriptHold))
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
        guard authorized(request) else { return refusal(request) }
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
        case ("POST", 1, "agent"):
            // An agent on a linked computer asking about the sessions here.
            return .json(linkedAgentReply(body).encoded())
        case ("GET", 1, "code"):
            // This computer's connection code, for a client that holds
            // several to link them (it is let in already, so the password
            // the code carries is no news to it).
            guard let code = connectionCode else { return HTTPResponse(503, Envelope.error("No connection code yet").encoded()) }
            var e = Envelope(type: "code")
            e.text = code.encoded
            return .json(e.encoded())
        case ("POST", 2, "push") where parts[1] == "key":
            // The APNs key, set from this Mac (a tool, an agent) rather than
            // in Settings: {"key": <the .p8's text>, "keyID": …, "teamID": …}.
            // Written, never read back.
            let fields = parseJSON(request.body)
            if let problem = setAPNsKey(pem: fields?["key"].string ?? "", keyID: fields?["keyID"].string ?? "",
                                        teamID: fields?["teamID"].string ?? "") {
                return HTTPResponse(400, Envelope.error(problem).encoded())
            }
            return .json(Envelope(type: "push").encoded())
        case ("POST", 2, "push") where parts[1] == "test":
            if let problem = sendTestPush() { return HTTPResponse(400, Envelope.error(problem).encoded()) }
            return .json(Envelope(type: "push").encoded())
        case ("POST", 1, "push"):
            // A device that wants to hear, with the app closed, when a turn
            // ends or an agent waits.
            guard registerPush(body) else { return HTTPResponse(400, Envelope.error("A push token and its app are required").encoded()) }
            // Whether pushes will come: the device then leaves them to us.
            var reply = Envelope(type: "push")
            reply.exists = apnsKey.configured
            return .json(reply.encoded())
        case ("POST", 1, "link"):
            // A computer this one's code was pasted into, linking back.
            guard let code = body.text.flatMap(ConnectionCode.init(parsing:)) else {
                return HTTPResponse(400, Envelope.error("A connection code is required").encoded())
            }
            if code.host != address { adopt(code) }
            return .json(Envelope(type: "link").encoded())
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
                client.sendLast(.error("Not an agent of this host"))
                return
            }
            let request = ApprovalRequest(id: id, tool: envelope.text ?? "tool", summary: envelope.prompt ?? "")
            record.approvalWaiters[id] = client
            record.setPendingApproval(request)
            broadcast(.approval(session: record.info.id, request), session: record)
            broadcastSessions()
            return
        }
        // Sessions talking to each other, through the Visor MCP server each
        // agent runs: one request per connection, answered at once.
        if envelope.type == "agent" {
            answerAgent(envelope) { reply in client.sendLast(reply) }
            return
        }
        if !client.authenticated {
            guard envelope.type == "login" else { client.send(.error("Log in first")); return }
            let token = envelope.token ?? ""
            let byPassword = !password.isEmpty && (envelope.password ?? "") == password
            guard byPassword || (!token.isEmpty && tokens.contains(token)) else {
                client.sendLast(.error("Wrong password"))
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
            rebuild(record, rereading: true)
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
            Task { client.send(await record.earlier(before: before)) }
        case "subscribe":
            guard let client, let record = session(envelope.session) else { return }
            record.subscribers.insert(ObjectIdentifier(client))
            // Bound before any turn: what the file says reaches subscribers
            // whether or not an agent of ours has run.
            if !record.isBound { bind(record) }
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
            waiter.sendLast(answer)
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


    /// Ends the agent and makes a new one on the same session, which
    /// picks the conversation up as the file stands: one built for the
    /// session as it is now (its folder, its mode). A turn in flight is
    /// cut short. A terminal starts as soon as the old agent is gone; the
    /// chat's agent starts with the next message, which is when resuming
    /// matters. With `rereading`, the transcript is read again, since the
    /// file may have moved on under another writer.
    private func rebuild(_ record: SessionRecord, rereading: Bool = false) {
        record.restartWhenIdle = false
        let old = record.process
        record.replaceProcess(makeProcess(record.info, resume: old.resumeID))
        // The old agent goes first: until it has, what is said waits.
        record.held = true
        // It is no longer heard, so its turn is ended here.
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        Task {
            await old.end(within: .seconds(3))
            if record.info.mode.isTUI { launchTerminal(record) }
            if rereading { record.followFile() }
            release(record)
        }
    }

    /// The agent before this one is gone: what waited for that goes over.
    private func release(_ record: SessionRecord) {
        record.held = false
        guard !record.info.archived, !record.info.busy, !record.info.queued.isEmpty else { return }
        let waiting = record.takeQueue()
        broadcastSessions()
        deliver(waiting.text, to: record, images: waiting.images)
    }

    /// A terminal is live before anything is said: bound and started now.
    private func launchTerminal(_ record: SessionRecord) {
        if !record.isBound { bind(record) }
        if let size = record.info.mode.terminalSize { record.terminal?.resize(cols: size.cols, rows: size.rows) }
        do { try record.terminal?.start() } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
        }
        saveArchive()
    }

    /// What an agent asked of the other sessions, answered: `mode` is the
    /// ask, `client` the asking session, `session` the one it is about.
    /// Only the agents this server started hold the token.
    func agentReply(_ envelope: Envelope) -> Envelope {
        guard envelope.token == agentToken, let caller = session(envelope.client) else {
            var reply = Envelope(type: "agent_result")
            reply.id = envelope.id
            reply.error = "Not an agent of this computer"
            return reply
        }
        let name = caller.info.title.isEmpty ? caller.info.agent.title : caller.info.title
        return answer(envelope, from: caller.info.id, named: name, on: nil)
    }

    /// The same asks from an agent on a linked computer, which that
    /// computer's server forwards (`POST /api/agent`): `client` is the
    /// caller as `<computer>/<id>`, `title` its name, `host` the computer.
    func linkedAgentReply(_ envelope: Envelope) -> Envelope {
        guard let caller = envelope.client, caller.contains("/") else {
            var reply = Envelope(type: "agent_result")
            reply.id = envelope.id
            reply.error = "Not an agent of a linked computer"
            return reply
        }
        return answer(envelope, from: caller, named: envelope.title ?? caller, on: envelope.host)
    }

    private func answer(_ envelope: Envelope, from caller: String, named name: String, on computer: String?) -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = envelope.id
        let others = sessions.filter { $0.info.id != caller && !$0.info.ended && !$0.info.archived }
        switch envelope.mode {
        case "sessions":
            reply.text = others.isEmpty ? "No other sessions." : others.map { record in
                let info = record.info
                return "\(info.id) — \(info.title.isEmpty ? info.agent.title : info.title) (\(info.agent.title), \(info.busy ? "working" : "idle")) in \(info.cwd)"
            }.joined(separator: "\n")
        case "send":
            guard let target = others.first(where: { $0.info.id == envelope.session }) else {
                reply.error = "No other session with that id; list_sessions names them."
                return reply
            }
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                reply.error = "Nothing to send."
                return reply
            }
            // Marked as another agent's, so it is not taken for the user's.
            let marked = "[Message from the Visor session “\(name)” (\(caller))\(computer.map { " on \($0)" } ?? ""), not from the user. "
                + "To answer, use send_message to that session.]\n\n" + text
            let busy = target.info.busy
            deliver(marked, to: target)
            let targetName = target.info.title.isEmpty ? target.info.agent.title : target.info.title
            reply.text = busy ? "Queued for \(targetName): it is working and takes it when its turn ends." : "Sent to \(targetName)."
        case "read":
            guard let target = others.first(where: { $0.info.id == envelope.session }) else {
                reply.error = "No other session with that id; list_sessions names them."
                return reply
            }
            let count = max(1, min(envelope.rows ?? 10, 50))
            reply.text = target.entries.suffix(count).map { row in
                let words = row.text.count > 2000 ? String(row.text.prefix(2000)) + "…" : row.text
                let calls = row.activities.isEmpty ? "" : " [" + row.activities.joined(separator: "; ") + "]"
                return "\(row.role.rawValue): \(words)\(calls)"
            }.joined(separator: "\n\n")
        default:
            reply.error = "Unknown request"
        }
        return reply
    }

    private func deliver(_ text: String, to record: SessionRecord, images: [String] = []) {
        // A turn in flight is left alone. What the user says now waits its
        // turn and goes over as soon as the agent falls idle — interrupting
        // is a deliberate act (`stop`), not the cost of typing.
        // A terminal at a prompt (trust this folder? accept bypass mode?
        // allow this tool?) is not at its input box: typed text would answer
        // the prompt with its default. The message waits until it is.
        // Nor is anything said while the agent before this one is going.
        if record.info.busy || record.held || (record.terminal.map { !$0.ready } ?? false) {
            record.enqueue(text, images: images)
            saveArchive()
            broadcastSessions()
            return
        }
        record.appendUser(text, images: images)
        // Written down before the turn runs: if the app is killed while the
        // agent is working, the message the user sent is still here when it
        // comes back (the store is otherwise written at the end of a turn),
        // and `interrupted` says a reply is still owed.
        record.interrupted = true
        saveArchive()
        // The adapter's events reach subscribers through the record; bound
        // once, the first time the session takes a turn.
        if !record.isBound { bind(record) }
        var forAgent = text
        if !images.isEmpty {
            let list = images.map { "- " + $0 }.joined(separator: "\n")
            // Pictures by that name; with a video among them, files — the
            // agent reads a video by the tools it has, not as a picture.
            let pictures = images.allSatisfy { AgentImages.pixelSize(path: $0) != nil }
            let heading = pictures ? (images.count == 1 ? "Attached image:" : "Attached images:")
                                   : (images.count == 1 ? "Attached file:" : "Attached files:")
            forAgent = (text.isEmpty ? "" : text + "\n\n") + heading + "\n" + list
        }
        do {
            try record.process.send(forAgent)
            // The spawn happened inside `send`, so the pid is knowable
            // only now — and it is what finds this agent again if we are
            // killed outright.
            saveArchive()
            // Working from now, not from when the agent says so: what the
            // user sends next (a command after its words, split by the
            // client) waits for this turn rather than landing inside it.
            if !record.info.busy { broadcast(record.apply(.busy(true)), session: record) }
        } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
            broadcast(record.apply(.busy(false)), session: record)
            // Not where the tools usually are: the login shell is asked,
            // so the next try knows.
            if case AgentProcessError.toolMissing(let tool) = error { Task { await ToolPath.locate([tool]) } }
        }
    }

    private func bind(_ record: SessionRecord) {
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
        record.listen { [weak self, weak record] event in
            guard let self, let record else { return }
            self.handle(event, from: record)
        }
    }

    /// One thing an agent did: applied to its session's record, and told
    /// to whoever watches it.
    private func handle(_ event: AgentEvent, from record: SessionRecord) {
        let reported = record.info.reportedModel
        // Nothing to say is nothing sent: terminal bytes went to the one
        // window they are drawn for inside apply.
        broadcast(record.apply(event), session: record)
        switch event {
        case .context, .session:
            // These land in the session list, not an envelope.
            broadcastSessions()
        case .model:
            if record.info.reportedModel != reported { broadcastSessions() }
        case .commands(let list):
            keepCommands(list, for: record.info.agent)
        case .busy(let busy):
            // The turn's status lines, whole, whenever they change.
            if !busy { broadcast(.status(session: record.info.id, items: []), session: record) }
            if !busy, !record.approvalWaiters.isEmpty {
                for waiter in record.approvalWaiters.values { waiter.close() }
                record.approvalWaiters.removeAll()
            }
            // The agent's own id appears with the first turn; the
            // transcript is written down whenever a turn ends.
            record.refreshResume()
            if !busy { record.interrupted = false; saveArchive() }
            broadcastSessions()
            // An archived session takes no turns, and one whose last
            // agent is still going waits for it.
            guard !busy, !record.info.archived, !record.held else { return }
            if record.restartWhenIdle {
                // Rebuilt rather than merely stopped: a flag the agent
                // takes at launch (its permission mode, its model)
                // survives a restart of the same object, but its
                // directory does not — that is fixed when the process is
                // made. What waited goes over once the old agent is gone.
                rebuild(record)
            } else if !record.info.queued.isEmpty {
                // Everything said during the turn goes over as one turn,
                // in the order it was said.
                let waiting = record.takeQueue()
                broadcastSessions()
                deliver(waiting.text, to: record, images: waiting.images)
            }
        default:
            break
        }
    }

    func session(_ id: String?) -> SessionRecord? {
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
        notifyPushes()
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
        var destination = Bundle.main.bundlePath
        var install = ""
        if let bundle, !bundle.isEmpty {
            let source = (bundle as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source + "/Contents/MacOS") else {
                return "No app bundle at \(source)"
            }
            let incoming = Bundle(path: source)
            let identifier = incoming?.bundleIdentifier ?? ""
            let replaces = incoming?.object(forInfoDictionaryKey: "VisorReplaces") as? [String] ?? []
            if identifier == Bundle.main.bundleIdentifier {
                if source != destination {
                    install = "rm -rf \(Self.shellQuoted(destination)) && cp -R \(Self.shellQuoted(source)) \(Self.shellQuoted(destination)) || exit 1\n"
                }
            } else if let current = Bundle.main.bundleIdentifier, replaces.contains(current) {
                // The app that takes over from this one: installed beside it
                // under its own name, this one removed, and anything that
                // opened this one at login (a LaunchAgent) pointed at it.
                let replacement = ((destination as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent((source as NSString).lastPathComponent)
                let agents = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
                install = """
                rm -rf \(Self.shellQuoted(replacement)) && cp -R \(Self.shellQuoted(source)) \(Self.shellQuoted(replacement)) || exit 1
                rm -rf \(Self.shellQuoted(destination))
                for f in \(Self.shellQuoted(agents))/*.plist; do
                  grep -qF \(Self.shellQuoted(destination)) "$f" 2>/dev/null && sed -i '' "s#\(destination)#\(replacement)#g" "$f"
                done

                """
                destination = replacement
            } else {
                return "\(source) is \(identifier.isEmpty ? "not an app" : identifier), not \(Bundle.main.bundleIdentifier ?? "this app")"
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
        // Once the answer to whoever asked has gone out.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            quit()
        }
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
    public func endAll() async {
        for record in sessions where record.info.busy { record.interrupted = true }
        saveArchive()
        // What the agents say as they go is not heard: the record of the
        // shutdown is the one just written.
        for record in sessions { record.stopListening() }
        // Waited for, not merely asked: an agent that outlives the app
        // runs on with nobody at the other end of its pipes. All at once:
        // each has its own few seconds to go.
        let ending = sessions.map { record in Task { await record.process.end(within: .seconds(4)) } }
        for task in ending { await task.value }
        agentsEnded = true
    }

    /// The agents have been ended for a quit: nothing is left to wait for.
    public private(set) var agentsEnded = false

    /// Ends the agents, then the app. The way to quit from the app's own
    /// code: the agents are gone before the app is asked to terminate, so
    /// it has nothing to wait for then.
    public func quit() {
        Task {
            await endAll()
            NSApplication.shared.terminate(nil)
        }
    }
}
