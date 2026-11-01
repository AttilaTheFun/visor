// Visor on the Mac (docs/co-tenancy.md, "The app"): a menu bar app, the eye
// in the bar with the server's menu, whose window is Visor's macOS client,
// and the Mac's Visor server under both. It takes over from Visor Server and
// the Mac client (Info.plist's VisorReplaces: a server update installs it in
// Visor Server's place), keeping their keychain items, caches and data where
// they were (FormerApps).

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
        // The server's own, where Visor Server kept them: its keychain
        // items and its store. Then the server, before anything asks for it.
        ServerCache.shared = .open(named: "messages", in: FormerApps.folder(of: FormerApps.server))
        ServerPlatform.current = .apple(secrets: KeychainSecrets(service: FormerApps.server))
        server = VisorServer.shared
        // The client's own, where the Mac client kept them: its cache and its
        // keychain items. Then its services, which the store connects through.
        AgentServerConnection.cache = .open(named: "messages", in: FormerApps.folder(of: FormerApps.client))
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(),
                             settings: NativeVisorSettingsService(keychainService: FormerApps.client),
                             notifications: NativeVisorNotificationService(), ssh: NativeVisorSSHService(), network: NativeVisorNetworkService(),
                             dictation: NativeVisorDictationService(), deviceName: Host.current().localizedName ?? "",
                             appVersion: Self.bundleVersion, platformName: "macOS")
        if !VisorFixture.active {
            // (The push token is asked for once launched: AppDelegate.)
            VisorHost.notifications?.requestPermission()
        }
        _store = State(initialValue: VisorStore())
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
