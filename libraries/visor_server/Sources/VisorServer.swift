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


@MainActor
public final class VisorServer: ObservableObject {
    /// The one server of the menu bar app.
    public static let shared = VisorServer()

    @Published public internal(set) var sessions: [SessionRecord] = []

    @Published public internal(set) var clientCount = 0

    @Published public internal(set) var listening = false

    @Published public internal(set) var lastError: String?
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

    /// The network user this Mac belongs to, as the exposure reports it;
    /// requests the road names as theirs need no password.
    @Published public internal(set) var hostLogin: String?
    /// This Mac's name on the network ("my-mac.tail1234.ts.net"), once the

    /// exposure has said it; learned with the owner, so the menu shows it
    /// even when Tailscale came up after the app did.
    @Published public internal(set) var address: String?
    /// What went wrong putting the front in place, or nil.
    @Published public internal(set) var serveError: String?
    /// The other computers' servers this one's agents reach (VisorServer+Links.swift).
    @Published public internal(set) var links: [ConnectionCode] = []

    /// The slash commands each agent listed when it last ran (VisorServer+Commands.swift).
    var knownCommands: [AgentKind: [SlashCommand]] = [:]

    /// The devices that asked for pushes, what each session last looked like,
    /// and what sends them (VisorServer+Push.swift).
    var pushDevices: [PushDevice] = VisorServer.keptPushDevices()

    var pushStates: [String: PushState] = [:]

    let apnsSender = APNsSender()

    /// Told each push as it is decided, before anything is sent (tests).
    var onPush: ((_ title: String, _ body: String, _ session: String, _ kind: String) -> Void)?
    var modelsRefresh: Task<Void, Never>?
    /// The `front()` under way; and how many have found Tailscale not ready.
    var fronting: Task<Void, Never>?
    /// Asked for while an attempt ran: run again once it ends.
    var frontAgain = false

    var frontAttempts = 0

    /// Tokens handed out by `hello` to clients the road (or the password)
    /// let in, for the socket's login; new each launch.
    var tokens: [String] = []

    public let port: UInt16

    var listener: NWListener?
    var http: HTTPServer?
    var connections: [ObjectIdentifier: ClientConnection] = [:]

    /// The REST side, beside the WebSocket: `port + 1`.
    public var apiPort: UInt16 { port + 1 }

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

    /// How clients reach this server; Tailscale unless a fork says otherwise.
    public var exposure: any ServerExposure = TailscaleExposure()

    /// The connection code a client takes to add this computer in one
    /// step: its name, its address, the password. Nil until the address
    /// is known and a password is set.
    public var connectionCode: ConnectionCode? {
        guard !password.isEmpty, let address else { return nil }
        return ConnectionCode(name: hostName, host: address, password: password)
    }

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
    public var backends: AgentBackends = .standard

    public var hostName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name
    }

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
    var transcriptWaiters: [String: [(revision: Int, generation: Int, respond: (HTTPResponse) -> Void)]] = [:]

    static let transcriptHold: TimeInterval = 25

    /// The list, once, after a burst: a turn writes a row per tool call.
    var sessionsBroadcastPending = false

    /// The agents have been ended for a quit: nothing is left to wait for.
    public internal(set) var agentsEnded = false
}
