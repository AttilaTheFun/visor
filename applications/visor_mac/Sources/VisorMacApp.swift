// Visor on the Mac: a menu bar app, the eye
// in the bar with the server's menu, whose window is Visor's macOS client,
// and the Mac's Visor server under both, each keeping what it has in places
// of its own (MacPlaces).

import AppKit
import MessageCache
import SwiftUI
import VisorClient
import VisorDriver
import VisorNativeRunner
import VisorProtocol
import VisorServer
import VisorServerApple
import VisorServices
import VisorUI

@main
struct VisorMacApp: App {
    private let server: VisorServer
    @State private var store: VisorStore
    /// The server's life, the client's pushes and the Dock icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The window that is Visor's client.
    static let mainWindow = "main"

    /// This app's version and build ("0.31 (8)").
    static var bundleVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return VersionTitle.of(version: short, build: build)
    }

    init() {
        // The server's own: its keychain items and its store. Then the
        // server, before anything asks for it.
        ServerCache.shared = .open(named: "messages", in: MacPlaces.folder("Server"))
        ServerPlatform.current = .apple(secrets: KeychainSecrets(service: MacPlaces.serverService))
        server = VisorServer.shared
        // An unattended setup (a leased test VM, tools/e2e): the first
        // password from the environment (launchctl setenv, so it's on no
        // disk), kept as Settings' Save would keep it. Never replaces one
        // already kept.
        if server.password.isEmpty, let given = ProcessInfo.processInfo.environment["VISOR_SETUP_PASSWORD"], !given.isEmpty {
            server.password = given
        }
        Self.startAgentProtocol(server)
        // The client's own: its cache and its keychain items. Then its
        // services, which the store connects through.
        AgentServerConnection.cache = .open(named: "messages", in: MacPlaces.folder("Client"))
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(),
                             settings: NativeVisorSettingsService(keychainService: MacPlaces.clientService),
                             notifications: NativeVisorNotificationService(), ssh: NativeVisorSSHService(), network: NativeVisorNetworkService(),
                             dictation: NativeVisorDictationService(), deviceName: Host.current().localizedName ?? "",
                             appVersion: Self.bundleVersion, platformName: "macOS")
        if !VisorFixture.active {
            // (The push token is asked for once launched: AppDelegate.)
            VisorHost.notifications?.requestPermission()
        }
        // The welcome is this Mac's: its server a password away.
        VisorOnboardings.current = MacOnboarding(server: server)
        let store = VisorStore()
        _store = State(initialValue: store)
        // This Mac's server among the computers, without pairing.
        if !VisorFixture.active { OwnServer.follow(server, in: store) }
    }

    /// agent_protocol on this Mac (Logan, 12 Nov 2026): the server as driver
    /// and dispatcher on loopback, and the native runner, which runs each
    /// job's agent under the agent-wrapper in this app's Helpers. Its jobs'
    /// harness is the `AgentJobHarness` default (claude unless set; echo
    /// for a test without a model). `AgentProtocolContainerURL`, when set,
    /// is how containers reach them (MultiPass's dial-in:
    /// `http://visor.multipass.internal:7434`).
    private static func startAgentProtocol(_ server: VisorServer) {
        let port = 7434
        let url = "http://127.0.0.1:\(port)"
        let harness = UserDefaults.standard.string(forKey: "AgentJobHarness") ?? "claude"
        let containerURL = UserDefaults.standard.string(forKey: "AgentProtocolContainerURL")
        _ = VisorDriver.start(server, host: "127.0.0.1", port: port, url: url, containerURL: containerURL, harness: harness)
        let wrapper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-wrapper").path
        guard FileManager.default.isExecutableFile(atPath: wrapper),
              let runner = NativeRunner(dispatcher: url, wrapper: wrapper, name: Host.current().localizedName ?? "Mac",
                                        log: { VisorDriver.log($0) }) else { return }
        Task { await runner.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            VisorMenu(server: server)
        } label: {
            Image(systemName: server.listening ? "eye" : "eye.slash")
        }
        Window("Visor", id: Self.mainWindow) {
            VisorRootView()
                .environment(store)
                // The sidebar at its ideal (300: AppKit lays the columns out
                // at their ideal widths), the detail's least (440) and
                // Settings' inspector at its ideal (320), with room: at 980
                // the detail got 360 and the chat ran under its composer.
                .frame(minWidth: 1_100, minHeight: 480)
                // visor://connect?code=… — a connection code from a QR code
                // or a link adds that computer; visor://sign-in shows a
                // computer's settings.
                .onOpenURL { url in store.open(url.absoluteString) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .background(SceneOpeners())
        }
        .handlesExternalEvents(matching: ["*"])
        // Shown at launch: a menu bar app's window is not, unless asked.
        .defaultLaunchBehavior(.presented)
        // The sidebar, and a thread about as wide as the transcript grows.
        .defaultSize(width: 1200, height: 820)
        .commands {
            // ⌘Q closes the window, back to the menu bar: quitting ends the
            // server's agents, which only the menu's Quit Visor does.
            CommandGroup(replacing: .appTermination) {
                Button("Close Visor") { AppDelegate.backToTheMenuBar() }
                    .keyboardShortcut("q")
            }
            CommandMenu("Computers") {
                ForEach(store.servers) { host in
                    Button("\(host.record.name.isEmpty ? host.record.address : host.record.name) — \(host.state.label)") {
                        host.disconnect()
                        host.connect()
                    }
                }
                if !store.servers.isEmpty { Divider() }
                Button(AgentServerProviderUIs.addTitle + "…") { store.addingServer = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsPane(server: server)
        }
    }
}
