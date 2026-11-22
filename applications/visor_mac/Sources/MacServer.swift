// The Mac's Visor server started: the one code path the server in the app
// (VisorMacApp, LocalServer) and the server agent (`Visor --server`,
// MacServerAgent) share. The same data folder (on the Visor volume once
// it's there, else Application Support/Visor: MacPlaces), keychain items
// (MacPlaces' server service), message cache, ports (7433, and
// agent_protocol's 7434), socket file and native runner, whichever process
// runs it.

import DiskVolumes
import Foundation
import MessageCache
import VisorDriver
import VisorNativeRunner
import VisorServer
import VisorServerApple

@MainActor
enum MacServer {
    /// The server's platform given, before anything asks for it: the app's
    /// relauncher in the app, launchd's restart in the agent. Given in every
    /// process of the app's, even one whose server is the agent: its
    /// keychain items are read through it.
    /// `runsServer`: this process will run the server, so what was in the
    /// home folder moves onto the Visor volume first (MacPlaces.settle);
    /// `client`: it's the app, whose own cache moves too. Whether the Visor
    /// volume holding the data is missing.
    @discardableResult
    static func prepare(lifecycle: (any ServerLifecycle)? = nil, runsServer: Bool, client: Bool,
                        log: (@Sendable (String) -> Void)? = nil) -> Bool {
        let missing = MacPlaces.settle(runsServer: runsServer, client: client, log: { line in
            NSLog("Visor: %@", line)
            log?(line)
        })
        // The socket file on the Visor volume, when it's there; in the app
        // group's container instead when that's set (MacPlaces'
        // `groupSockets`), the agents' hosts' beside it, and the volume's
        // and ~/.visor's links to it for a release.
        let group = MacPlaces.groupPlaces
        VisorServer.placedSocketPath = MacPlaces.socket
        VisorServer.legacySocketLinks = MacPlaces.socketLinks
        VisorServer.placedHostSocketFolder = group?.socketFolder
        var platform = ServerPlatform.apple(secrets: MacSecrets.make(), lifecycle: lifecycle ?? AppLifecycle(), data: MacPlaces.data)
        if let log {
            let system = platform.log
            platform.log = { line in
                system(line)
                log(line)
            }
        }
        ServerPlatform.current = platform
        return missing
    }

    /// The server made, with what runs beside it: its store, agent_protocol's
    /// port open before the sessions are read (the wrappers and runners of
    /// sessions moved to runners redial it), the first password from the
    /// environment, and the native runner. Not yet listening: `start`.
    static func make() -> VisorServer {
        ServerCache.shared = .open(named: "messages", in: MacPlaces.folder("Server"))
        let agentProtocol = agentProtocol()
        agentProtocol.listen()
        // The admin token itself kept beside its hash, for `Visor
        // admin-token` (MacAdminTokenCommand).
        VisorServer.keepsAdminToken = true
        let server = VisorServer.shared
        // Sessions moved in from another computer, and Super Compact's new
        // sessions, on the Sessions volume when it's there.
        server.arrivalRoot = DiskVolumes.locate(dataDirectory: MacPlaces.folders.data).sessions.readyPath
        // Visor.app is this server's client at its socket file, from the
        // start (password or none, sshEnabled or not), and its menu's own
        // calls are taken from it alone: by the key the keychain keeps,
        // asked again when a call doesn't show it (AppKeyKeeper).
        server.appKey = MacAppKey.made()
        server.appKeyAskedAgain = { MacAppKey.reconciled($0) }
        // An unattended setup (a leased test VM, tools/e2e): the first
        // password from the environment (launchctl setenv, so it's on no
        // disk), kept as Settings' Save would keep it. Never replaces one
        // already kept.
        if server.password.isEmpty, let given = ProcessInfo.processInfo.environment["VISOR_SETUP_PASSWORD"], !given.isEmpty {
            server.password = given
        }
        startAgentProtocol(agentProtocol, serving: server)
        return server
    }

    /// Whether the server kept has a password (or asks for none): it serves
    /// once it has. Read without making a server.
    static var hasPassword: Bool {
        if !(ServerPlatform.current.secrets.get("password") ?? "").isEmpty { return true }
        if !(ProcessInfo.processInfo.environment["VISOR_SETUP_PASSWORD"] ?? "").isEmpty { return true }
        return ServerSettings.kept(at: VisorServer.settingsURL).asksNothing
    }

    /// agent_protocol on this Mac (Logan, 12 Nov 2026): the server as driver
    /// and dispatcher on loopback, and the native runner, which runs each
    /// job's agent under the agent-wrapper in this app's Helpers. Its jobs'
    /// harness is the `AgentJobHarness` default (claude unless set; echo
    /// for a test without a model). Containers reach them as
    /// `AgentProtocolContainerURL` says, else through Shireworks'
    /// agent-proxy (`http://visor.agent.internal:7434`).
    private static func agentProtocol() -> VisorDriver.Listening {
        let port = agentProtocolPort
        let harness = UserDefaults.standard.string(forKey: "AgentJobHarness") ?? "claude"
        let set = UserDefaults.standard.string(forKey: "AgentProtocolContainerURL") ?? ""
        let containerURL = set.isEmpty ? VisorDriver.containerURL(port: port) : set
        return VisorDriver.Listening(host: "127.0.0.1", port: port, url: agentProtocolURL, containerURL: containerURL, harness: harness)
    }

    /// The driver's port on loopback (the Sessions container's driver link goes to it).
    static let agentProtocolPort = 7434
    private static var agentProtocolURL: String { "http://127.0.0.1:\(agentProtocolPort)" }

    /// The server served, and the native runner pulling from it, with a
    /// runner token of its own.
    private static func startAgentProtocol(_ agentProtocol: VisorDriver.Listening, serving server: VisorServer) {
        agentProtocol.serve(server)
        let url = agentProtocolURL
        let wrapper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-wrapper").path
        // Its own runner token, so it claims when runner tokens are required.
        let name = Host.current().localizedName ?? "Mac"
        guard FileManager.default.isExecutableFile(atPath: wrapper),
              let runner = NativeRunner(dispatcher: url, wrapper: wrapper, name: name, token: agentProtocol.runnerToken(for: name),
                                        log: { VisorDriver.log($0) }) else { return }
        Task { await runner.run() }
    }
}
