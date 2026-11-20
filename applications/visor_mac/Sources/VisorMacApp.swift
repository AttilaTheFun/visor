// Visor on the Mac: a menu bar app, the eye
// in the bar with the server's menu, whose window is Visor's macOS client,
// and the Mac's Visor server under both, each keeping what it has in places
// of its own (MacPlaces).

import AppKit
import SwiftUI
import VisorClient
import VisorProtocol
import VisorServer
import VisorServices
import VisorUI

/// Started by VisorMacMain, once it's no agent-proxy and no server agent.
struct VisorMacApp: App {
    /// This Mac's server: in the app, or the server agent (LocalServer).
    private let local: LocalServer
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
        // The server's own: its keychain items. Then the server, before
        // anything asks for it: made here, as it always was, unless it runs
        // as the server agent (LocalServer, MacServer).
        MacServer.prepare()
        let local = LocalServer.shared
        self.local = local
        local.begin()
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
        VisorOnboardings.current = MacOnboarding(local: local)
        let store = VisorStore()
        _store = State(initialValue: store)
        // This Mac's server among the computers, without pairing.
        if !VisorFixture.active { local.follow(in: store) }
        // agent-proxy's launchd job, to settings.json's `agentProxy`, for
        // the server in the app (the server agent folds it in).
        if !VisorFixture.active, local.server != nil { MacAgentProxy.settle() }
    }

    var body: some Scene {
        MenuBarExtra {
            VisorMenu(local: local)
        } label: {
            Image(systemName: local.serving ? "eye" : "eye.slash")
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
            // A session as one file (Session archive v1), and one imported
            // to restore: the view opens each (VisorRootView).
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export…") { store.exportRequested = true }
                    .disabled(store.viewedSession == nil)
                Button("Import…") { store.importRequested = true }
                    .disabled(store.connectedServers.isEmpty)
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
            if let server = local.server {
                SettingsPane(server: server)
            } else {
                AgentServerSettings(local: local)
            }
        }
    }
}
