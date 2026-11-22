// The server: one listener for the WebSocket and the REST side (on
// loopback, or on every interface when the network is to reach it), a
// password on each caller, and the protocol's envelopes routed to the
// sessions (SessionRecord.swift), each of which is one agent. Sessions
// are written down and outlive the app.

import ClaudeTranscript
import Foundation
import MessageCache
import Observation
import VisorAgent
import VisorProtocol
import VisorSystem

@MainActor
@Observable
public final class VisorServer {
    /// The one server of the menu bar app.
    public static let shared = VisorServer()

    public internal(set) var sessions: [SessionRecord] = [] {
        // A session added has the MCP servers passed on to it.
        didSet { fillMCPSwitches() }
    }

    public internal(set) var clientCount = 0

    public internal(set) var listening = false

    public internal(set) var lastError: String?
    /// An update that did not stay up and was rolled back, as the
    /// relauncher said (VisorServer+Rollback.swift): shown until the next
    /// update.
    public internal(set) var updateNotice: String?
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
    package static var secrets: any SecretStore = ServerPlatform.current.secrets

    /// How the server is reached (ServerSettings): kept as set, and
    /// listened by again when how it listens changes.
    public var settings: ServerSettings = ServerSettings.kept(at: VisorServer.settingsURL) {
        didSet {
            guard settings != oldValue else { return }
            settings.keep(at: Self.settingsURL)
            if settings.reachableFromNetwork != oldValue.reachableFromNetwork || settings.tlsIdentityPath != oldValue.tlsIdentityPath
                || settings.sshEnabled != oldValue.sshEnabled {
                listenAgain()
            }
            if settings.lan != oldValue.lan || settings.vpn != oldValue.vpn { refusedPaths.removeAll() }
            if settings.detachAgents != oldValue.detachAgents { applyAgentDetaching() }
            // Asking nothing: a server with no password yet starts now.
            if settings.asksNothing, !oldValue.asksNothing, listener == nil { start() }
            if settings.mcpEndpoints != oldValue.mcpEndpoints {
                fillMCPSwitches()
                broadcastSessions()
            }
            if settings.container != oldValue.container || settings.agentProxy != oldValue.agentProxy { containerSettingsChanged() }
        }
    }
    /// The Sessions container's engine (VisorServer+Container), given by a
    /// Mac's background server; none elsewhere. Told of the settings as
    /// it's given.
    public var sessionsContainer: (any SessionsContainer)? {
        didSet {
            containerSettingsChanged()
            // The sessions placed in it, read before it was given: their
            // agents started in it now.
            if sessionsContainer != nil { resumeContainerSessions() }
        }
    }
    /// What each client connected here last said it is connected to, by
    /// the client's id (VisorServer+Directory.swift).
    var directory: [String: ClientDirectoryEntry] = [:]
    /// What the agents here sent to sessions on other servers, by message
    /// id, until a client carries each and brings back what became of it
    /// (VisorServer+RelayOutbox.swift).
    var relayOutbox: [String: RelayRecord] = VisorServer.keptRelayOutbox()
    /// What became of each message carried here from another server, by
    /// its id, so one carried twice is taken once
    /// (VisorServer+RelayDelivery.swift).
    var relayLedger: [String: RelayLedgerEntry] = VisorServer.keptRelayLedger()
    /// Agents waiting to hear what became of a message they sent
    /// elsewhere: by message id, then by waiter.
    var relayWaiters: [String: [String: (RelayRecord) -> Void]] = [:]
    /// Sessions moving to other servers, by their offers' tokens, and
    /// moving here, by their plans' ids (VisorServer+Migration.swift).
    var migrationsOut: [String: OutgoingMigration] = [:]
    var migrationsIn: [String: IncomingMigration] = [:]
    /// Session archives being uploaded to import, by their tokens
    /// (VisorServer+SessionArchive.swift).
    var importsIn: [String: IncomingImport] = [:]
    /// The bytes free on the disk a URL is on, which a move here must fit
    /// (VisorServer+MigrationSize.swift): the system's word, or a test's.
    var freeBytes: (URL) -> Int? = { VisorServer.systemFreeBytes($0) }
    /// The agent shims' connections waiting for an approval's answer: by
    /// session, then by request id. The server's, not the session's: a
    /// connection is a client of this server.
    var approvalWaiters: [String: [String: ClientConnection]] = [:]
    /// A folder for each session (VISOR_SESSIONS_DIR): nil where sessions
    /// work where they are asked to.
    public var sessionFolders: SessionFolders?
    /// Where a session moved here from another computer, and a Super
    /// Compact's new session, gets its folder (`<root>/<Agent>/<id>`) when
    /// the server keeps no folder for each session: the Sessions volume on
    /// a Mac that has one (Visor.app's), else nil, the data folder's
    /// `Sessions/` (VisorServer+MigrationArrival).
    public var arrivalRoot: String?
    /// The front this server sits behind when its auth is `none`
    /// (VISOR_TRUST and the headers it names): why a request is let in,
    /// and whom it names. Nil: anyone who reaches it, as `owner`.
    public var front: FrontTrust?
    /// Addresses connections were refused on (a path that is off), each
    /// logged once.
    var refusedPaths: Set<String> = []

    /// The slash commands each agent listed when it last ran (VisorServer+Commands.swift).
    var knownCommands: [AgentKind: [SlashCommand]] = [:]
    /// How each agent is paid for and how near its limits it is, as its
    /// sessions last said; read from disk when first wanted.
    var knownAccounts: [AgentKind: AgentAccount]?
    /// Each agent's last read of its account outright, and when it began
    /// (VisorServer+Accounts.swift).
    var accountReads: [AgentKind: (started: Double, task: Task<Void, Never>)] = [:]

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
    /// Tokens handed out by `hello` to clients the path (or the password)
    /// let in, for the socket's login; new each launch.
    var tokens: [String] = []
    /// Those of `tokens` handed out to a request the admin token let in (or
    /// one of these): gone when the admin token is rotated or reset.
    var adminHelloTokens: Set<String> = []

    public let port: UInt16

    var listener: (any Listener)?
    /// The socket file SSH clients reach, while `settings.sshEnabled`.
    var socketListener: (any Listener)?
    var http: HTTPServer?
    var connections: [ObjectIdentifier: ClientConnection] = [:]

    /// The one token every agent was given before each session had its
    /// own (0.59 and earlier), as kept (none if no build before kept one):
    /// taken only from a session whose agent, left under its host, was
    /// started with it (VisorServer+AgentTokens).
    let sharedAgentToken: String?

    /// Each session's random token of 0.60 and 0.61 (#421, #441), by
    /// session id, as kept: taken only from a session whose agent, left
    /// under its host, was started with it, until that agent is gone. New
    /// agents hold JWTs (`agentTokens`), kept nowhere.
    var sessionAgentTokens: [String: String]
    /// The agents' tokens, minted and verified with the signing keys kept
    /// with the secrets (AgentTokens): native sessions' and runners'
    /// agents'.
    package let agentTokens: AgentTokens
    /// The admin token's hash: kept with the secrets (the menu bar app's),
    /// or given at launch (the command-line server's:
    /// useAdminTokenGivenAtLaunch).
    package var adminToken: AdminToken
    /// Whether an emergency rotation of the signing keys (every other key
    /// dropped) may be asked over REST (`POST /api/keys/rotate
    /// {dropPrevious}`, `visor-server keys rotate --drop-previous`): the
    /// command-line server's, where there is no menu bar. Off in the menu
    /// bar app, whose menu is the only way (rotateSigningKeys).
    public var emergencyRotationOverREST = false
    /// What Visor.app shows at the socket file to be taken for itself, its
    /// menu and Settings (VisorServer+Access, `X-Visor-App-Key`): kept in
    /// the Mac's keychain, which gives it to Visor's own processes alone,
    /// and set by the Mac's binaries; nil elsewhere. While it is set, the
    /// socket file is listened on from the start, password or none, and
    /// whatever `sshEnabled` says (the app's way to its own server); and the
    /// menu's own calls, a reset of the admin token without it and an
    /// emergency rotation of the signing keys, are taken from it alone.
    public var appKey: String?
    /// Re-mints the native sessions' token files hourly
    /// (VisorServer+SessionTokenFiles).
    var sessionTokenRefresh: Task<Void, Never>?
    /// When each driven session's agent was last restarted for a wrapper
    /// that dialled in with an expired token (resumeAfterExpiredToken).
    var expiredTokenResumes: [String: Date] = [:]
    /// Driven sessions moving back whose runners' agents were asked to
    /// return their conversations, by session id (VisorServer+HandBack).
    var handingBack: [String: PendingHandBack] = [:]
    /// How long a move back waits for its runner's agent to begin returning
    /// its conversation before it carries on without it: 2 minutes.
    package var handBackWait: Duration = .seconds(120)
    /// How long it waits for a return that has begun to end: 5 minutes,
    /// the wrapper's own deadline for it (ConversationReturn.deadline).
    package var handBackReceiveWait: Duration = .seconds(300)
    /// How much a returned conversation may bring: a move's caps.
    package var handBackLimits = HandBackLimits()
    /// The runners' own tokens, which agent_protocol's Claim asks
    /// (RunnerTokens): kept with the secrets.
    package let runnerTokens: RunnerTokens

    /// Sessions this launch was asked to bring back into a running state:
    /// they were mid-turn when the app went away, and were named on the
    /// command line (or in VISOR_RESUME). Nudged once the listener is up.
    var pendingResumes: [String] = []
    /// The Super Compact job running, if one is: one at a time per server
    /// (VisorServer+SuperCompact).
    var superCompaction: SuperCompaction?

    public init(port: UInt16 = Envelope.defaultPort) {
        self.port = port
        password = Self.keptPassword()
        sharedAgentToken = Self.keptSharedAgentToken()
        sessionAgentTokens = Self.keptSessionAgentTokens()
        runnerTokens = RunnerTokens(secrets: Self.secrets)
        adminToken = AdminToken(keptIn: Self.secrets, keepingToken: Self.keepsAdminToken)
        // Its issuer is this server's id, made below the first time.
        agentTokens = AgentTokens(secrets: Self.secrets, issuer: "")
        Self.forgetRetiredSecrets()
        RetiredFiles.moveAside(in: HostFolders.dataFolder)
        applyAgentDetaching()
        if settings.serverID.isEmpty { settings.serverID = UUID().uuidString.lowercased() }
        agentTokens.issuer = id
        loadSessions()
        takeRollbackNote()
    }

    /// The GitHub proxy's token for this server, kept with the secrets
    /// until its proxy setup was removed (visor#422): nothing reads it
    /// now, so it is deleted at load.
    static let retiredGitHubProxyTokenKey = "github.proxyToken"

    /// Deletes the secrets no part of the server reads any more.
    static func forgetRetiredSecrets() {
        secrets.set(retiredGitHubProxyTokenKey, nil)
        secrets.set(retiredRunnerAgentTokensKey, nil)
    }

    /// The runners' agents' random tokens #438 kept before they were JWTs
    /// (never deployed): nothing reads them.
    static let retiredRunnerAgentTokensKey = "runnerAgentTokens"

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
        // Standing alone: the one address, none of the others.
        return ConnectionCode(name: hostName, host: address, password: password, id: id, paths: isStandalone ? [] : ownAddresses,
                              auth: settings.authentication)
    }

    /// Whether the server stands alone (`ServerSettings.standalone`, or
    /// VISOR_STANDALONE=1 in its environment, for a server a sandbox
    /// starts).
    public var isStandalone: Bool {
        settings.standalone || ProcessInfo.processInfo.environment["VISOR_STANDALONE"] == "1"
    }

    /// sessions.json in the platform's data directory (on a Mac
    /// ~/Library/Application Support/Visor; archive.json before sessions
    /// were all kept, read once and folded in).
    /// Tests point this at a scratch folder: a server built over the real
    /// archive ends the agents it records as orphans of a previous life.
    static var storeRoot: URL? {
        get { HostFolders.dataRoot }
        set { HostFolders.dataRoot = newValue }
    }
    static var storeURL: URL { HostFolders.dataFolder.appendingPathComponent("sessions.json", isDirectory: false) }

    /// Beside the sessions: the slash commands each agent last listed.
    static var commandsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("commands.json", isDirectory: false) }
    /// And each agent's account, as its sessions last said.
    static var accountsURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("accounts.json", isDirectory: false) }

    /// What a session is told when its turn was cut off by a restart. It
    /// arrives as a user turn, which is what it is: the agent's own process
    /// is gone, and only a new turn can start it again.
    static let resumeNudge = """
        [Visor] The Visor server restarted while you were working, so that turn was cut short \
        and whatever you were part-way through did not finish. Pick it up from where you left \
        off, checking the state of anything you had started before you carry on.
        """

    /// What an agent restarted from a client is told, when it was working.
    static let restartNudge = """
        [Visor] Your process was restarted from Visor while you were working, so that turn was cut \
        short and whatever you were part-way through did not finish. Pick it up from where you left \
        off, checking the state of anything you had started before you carry on.
        """

    /// False once a store failed to decode: nothing is written until the
    /// app is restarted against a file it understands.
    var storeIsReadable = true

    /// The last write of the sessions failed; cleared by the next that works.
    var savingFailed = false

    /// The agents the server serves; a host assigns its own before start.
    public var harnesses: AgentHarnesses = .standard
    /// The MCP servers passed on to the sessions' agents, and each
    /// session's conversation with them.
    let mcpProxy = MCPProxy()

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

    /// The process of a driven session as it is loaded (VisorDriver's:
    /// the wrapper's stream, waiting for it to dial again). None where no
    /// driver runs: such a session's agent runs here instead.
    package var drivenProcess: (@MainActor (SessionInfo) -> AgentProcess)?
    /// Where jobs for runners go (`POST /api/jobs`): VisorDriver's
    /// dispatcher. None where no dispatcher runs.
    package var jobs: (any AgentJobQueue)?
    /// The agents Visor starts itself in its Sessions container, for the
    /// sessions placed there (VisorServer+ContainerRunner): the driver
    /// asks it of their tokens.
    @ObservationIgnored package lazy var containerRunner = ContainerRunner(tokens: agentTokens) { [weak self] id in
        self?.session(id).map { !$0.info.archived }
    }

    /// The sessions' store, written once `archiveSaveDelay` after a change
    /// however many come in it (saveArchive): written whole on each, it
    /// was most of the gigabytes a day the Mac saw Visor write.
    var archiveSavePending = false
    /// How long a change waits to be written with those after it.
    var archiveSaveDelay: Duration = .seconds(30)

    /// The agents have been ended for a quit: nothing is left to wait for.
    public internal(set) var agentsEnded = false
}
