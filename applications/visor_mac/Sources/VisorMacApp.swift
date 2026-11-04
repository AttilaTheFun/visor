// Visor on the Mac (docs/co-tenancy.md, "The app"): a menu bar app, the eye
// in the bar with the server's menu, whose window is Visor's macOS client,
// and the Mac's Visor server under both. It takes over from Visor Server and
// the Mac client (Info.plist's VisorReplaces: a server update installs it in
// Visor Server's place), taking their keychain items, caches and settings
// into places of its own once (FormerApps).

import AppKit
import MessageCache
import SwiftUI
import VisorClient
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
        FormerApps.adoptClientSettings()
        // What Visor Server and the Mac client kept, copied into this app's
        // own places the first time (FormerApps): their keychain items, then
        // their folders.
        FormerApps.adoptKeychain(from: FormerApps.server, into: FormerApps.ownServerService)
        FormerApps.adoptKeychain(from: FormerApps.client, into: FormerApps.ownClientService)
        // The server's own: its keychain items and its store. Then the
        // server, before anything asks for it.
        ServerCache.shared = .open(named: "messages", in: FormerApps.adoptFolder(of: FormerApps.server, into: FormerApps.ownFolder("Server")))
        ServerPlatform.current = .apple(secrets: KeychainSecrets(service: FormerApps.ownServerService))
        server = VisorServer.shared
        // The client's own: its cache and its keychain items. Then its
        // services, which the store connects through.
        AgentServerConnection.cache = .open(named: "messages", in: FormerApps.adoptFolder(of: FormerApps.client, into: FormerApps.ownFolder("Client")))
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(),
                             settings: NativeVisorSettingsService(keychainService: FormerApps.ownClientService),
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

    var body: some Scene {
        MenuBarExtra {
            VisorMenu(server: server)
        } label: {
            Image(systemName: server.listening ? "eye" : "eye.slash")
        }
        Window("Visor", id: Self.mainWindow) {
            VisorRootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 480)
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
