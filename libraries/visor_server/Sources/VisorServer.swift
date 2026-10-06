// The server: one listener for the WebSocket and the REST side (on
// loopback, or on every interface when the network is to reach it), a
// password on each caller, and the protocol's envelopes routed to the
// sessions (SessionRecord.swift), each of which is one agent. Sessions
// are written down and outlive the app.

import ClaudeTranscript
import Foundation
import MessageCache
import Observation
import VisorProtocol

@MainActor
@Observable
public final class VisorServer {
    /// The one server of the menu bar app.
    public static let shared = VisorServer()

    public internal(set) var sessions: [SessionRecord] = []

    public internal(set) var clientCount = 0

    public internal(set) var listening = false

    public internal(set) var lastError: String?
    /// Required: the server does not listen without one. Every client and
    /// every tool on this computer signs in with it; the connection code
    /// carries it.
    public var password: String {
        didSet {
            Self.secrets.set("password", password)
            if listener == nil, !password.isEmpty { start() }
        }
    }

    /// Where the password is kept: the system's place for secrets (the
    /// platform's); tests swap in their own.
    static var secrets: any SecretStore = ServerPlatform.current.secrets

    /// The bundle ids this app had before, whose settings it takes over.
    static let formerBundleIDs = ["com.LoganShire.Visor.MenuBar"]

    /// How the server is reached (ServerSettings): kept as set, and
    /// listened by again when how it listens changes.
    public var settings: ServerSettings = ServerSettings.kept(at: VisorServer.settingsURL) {
        didSet {
            guard settings != oldValue else { return }
            settings.keep(at: Self.settingsURL)
            if settings.reachableFromNetwork != oldValue.reachableFromNetwork || settings.tlsIdentityPath != oldValue.tlsIdentityPath {
                listenAgain()
            }
        }
    }
    /// The other computers' servers this one's agents reach (VisorServer+Links.swift).
    public internal(set) var links: [ConnectionCode] = []

    /// The slash commands each agent listed when it last ran (VisorServer+Commands.swift).
    var knownCommands: [AgentKind: [SlashCommand]] = [:]
    /// How each agent is paid for and how near its limits it is, as its
    /// sessions last said; read from disk when first wanted.
    var knownAccounts: [AgentKind: AgentAccount]?

    /// The devices that asked for pushes, what each session last looked like,
    /// and what sends them (VisorServer+Push.swift).
    var pushDevices: [PushDevice] = VisorServer.keptPushDevices()

    var pushStates: [String: PushState] = [:]

    let apnsSender = APNsSender()
    /// Counts up when the APNs key is set: what a view showing it watches.
    var apnsKeyChanges = 0

    /// Told each push as it is decided, before anything is sent (tests).
    var onPush: ((_ title: String, _ body: String, _ session: String, _ kind: String) -> Void)?
    /// Told of each silent push of a session's state (tests listen).
    var onStatusPush: ((_ session: String, _ status: String) -> Void)?
    var modelsRefresh: Task<Void, Never>?
    /// Tokens handed out by `hello` to clients the road (or the password)
    /// let in, for the socket's login; new each launch.
    var tokens: [String] = []

    public let port: UInt16

    var listener: (any Listener)?
    var http: HTTPServer?
    var connections: [ObjectIdentifier: ClientConnection] = [:]

    /// What the permission shim presents instead of the password; new per launch.
    let agentToken = UUID().uuidString

    /// Sessions this launch was asked to bring back into a running state:
    /// they were mid-turn when the app went away, and were named on the
    /// command line (or in VISOR_RESUME). Nudged once the listener is up.
    var pendingResumes: [String] = []

    public init(port: UInt16 = Envelope.defaultPort) {
        self.port = port
        Self.adoptFormerFolders()
        password = Self.keptPassword()
        links = Self.keptLinks()
        loadSessions()
    }

    /// A server apart from the user's own: its own port, a folder of its
    /// own for what it keeps, the password given and held in memory, and
    /// reached from this computer only. For trying a build against real
    /// agents without touching the installed server's sessions or its
    /// keychain (tools/staging_server).
    public static func staging(port: UInt16, root: URL, password: String) -> VisorServer {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeRoot = root
        secrets = MemorySecrets()
        ServerCache.shared = .inMemory()
        let server = VisorServer(port: port)
        server.password = password
        return server
    }

    /// The connection code a client takes to add this computer in one
    /// step: its name, its address, the password. Nil until there is an
    /// address to give and a password is set.
    public var connectionCode: ConnectionCode? {
        guard !password.isEmpty, let address = reachableAddress else { return nil }
        return ConnectionCode(name: hostName, host: address, password: password)
    }

    /// sessions.json in the platform's data directory (on a Mac
    /// ~/Library/Application Support/Visor; archive.json before sessions
    /// were all kept, read once and folded in).
    /// Tests point this at a scratch folder: a server built over the real
    /// archive ends the agents it records as orphans of a previous life.
    static var storeRoot: URL?
    static var storeURL: URL {
        let base = storeRoot ?? ServerPlatform.current.host.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.json")
    }

    /// Beside the sessions: the slash commands each agent last listed.
    static var commandsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("commands.json") }
    /// And each agent's account, as its sessions last said.
    static var accountsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("accounts.json") }

    /// What a session is told when its turn was cut off by a restart. It
    /// arrives as a user turn, which is what it is: the agent's own process
    /// is gone, and only a new turn can start it again.
    static let resumeNudge = """
        [Visor] The Visor server restarted while you were working, so that turn was cut short \
        and whatever you were part-way through did not finish. Pick it up from where you left \
        off, checking the state of anything you had started before you carry on.
        """

    /// False once a store failed to decode: nothing is written until the
    /// app is restarted against a file it understands.
    var storeIsReadable = true

    /// The last write of the sessions failed; cleared by the next that works.
    var savingFailed = false

    /// The agents the server serves; a host assigns its own before start.
    public var harnesses: AgentHarnesses = .standard

    public var hostName: String { ServerPlatform.current.host.name }

    /// The HTTP API: the same commands as the WebSocket, one request each,
    /// with the password as a bearer token. Paths may carry whatever a
    /// front mounted the API under, before `/api`.
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
    var transcriptWaiters: [String: [(revision: Int, generation: Int, respond: (HTTPResponse) -> Void)]] = [:]

    static let transcriptHold: TimeInterval = 25

    /// The list of sessions' revision, counting up with each change, and
    /// those holding for the next (VisorServer+Polling).
    var sessionsRevision = 1
    var sessionsWaiters: [(HTTPResponse) -> Void] = []
    /// Those holding for a session's ephemeral state to change, by session.
    var stateWaiters: [String: [(HTTPResponse) -> Void]] = [:]

    /// The list, once, after a burst: a turn writes a row per tool call.
    var sessionsBroadcastPending = false

    /// The agents have been ended for a quit: nothing is left to wait for.
    public internal(set) var agentsEnded = false
}
