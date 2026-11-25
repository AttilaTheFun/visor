// Visor on the Mac: a menu bar app, the eye
// in the bar with the server's menu, whose window is Visor's macOS client,
// and the Mac's Visor server under both, in the app's own process (0.72.1:
// LocalServer; started at login and after a crash by the app's launchd
// agent, MacAppInstance), each keeping what it has in places of its own
// (MacPlaces). The menu, Settings and the window are the server's clients
// alike, at its socket file.

import AppKit
import ShireworksKit
import SwiftUI
import VisorClient
import VisorProtocol
import VisorServer
import VisorServerPOSIX
import VisorServices
import VisorSocketFile
import VisorUI

/// Started by VisorMacMain, once it's no command or agent of its own, and
/// the only instance.
struct VisorMacApp: App {
    /// This Mac's server, in the app (LocalServer).
    private let local: LocalServer
    @State private var store: VisorStore
    /// The server's life, the client's pushes and the Dock icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The window that is Visor's client.
    static let mainWindow = "main"

    /// Where a bug reported from the menu, with no window open, is filed:
    /// the Info.plist's ShireworksRepository (CI stamps it in), else this
    /// repository.
    static var reportRepository: String { CrashesConfiguration.main.repository ?? "AttilaTheFun/visor" }

    /// This app's version and build ("0.31 (8)").
    static var bundleVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return VersionTitle.of(version: short, build: build)
    }

    init() {
        // Where Visor's things are, the home folder's moved onto the Visor
        // volume first (MacPlaces), unless the server agent of the builds
        // before may still be serving from them; the server's own: its
        // keychain items, and its log. Then the server, before anything asks
        // for it: made here, or once the server agent is handed back
        // (LocalServer, MacServer).
        let agentMayBeThere = LocalServer.agentMayBeThere
        let missing = MacServer.prepare(runsServer: !agentMayBeThere && MacAppInstance.lockProblem == nil, client: true)
        MacServer.logToFile()
        // Started by launchd (at login, the Visor volume can come after it)
        // with the data on a volume that isn't mounted: it ends rather than
        // serve from an empty folder, an exit of 1, for launchd to start it
        // again, as the server agent did.
        if missing, MacAppInstance.fromAgent {
            ServerPlatform.current.log("Visor ends for now: its data is on the Visor volume, which isn't mounted; launchd starts it again")
            exit(1)
        }
        let local = LocalServer.shared
        self.local = local
        local.begin(agentMayBeThere: agentMayBeThere)
        // The client's own: its cache and its keychain items. Then its
        // services, which the store connects through.
        AgentServerConnection.cache = .open(named: "messages", in: MacPlaces.folder("Client"))
        // An export's staging on the Visor volume (emptied at each start).
        SessionExport.staging = MacPlaces.folders.temporary
        // This Mac's own server at its socket file (SocketFileURL), with the
        // app's key; every other computer as before.
        let socketFile = SocketFileHTTPService(connect: { await POSIXUnixSocket.connect($0) }, headers: { MacAppKey.headers })
        let socketFileChannel = SocketFileSocketService(connect: { await POSIXUnixSocket.connect($0) }, headers: { MacAppKey.headers })
        installVisorServices(socket: SocketFileRoutedSocketService(socketFile: socketFileChannel, other: NativeVisorSocketService()),
                             http: SocketFileRoutedHTTPService(socketFile: socketFile, other: NativeVisorHTTPService()),
                             settings: MacClientSettings(moving: !VisorFixture.active),
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
        // This Mac's server among the computers, without pairing. (agent-proxy
        // runs inside it, folded in as it starts: MacServer.run.)
        if !VisorFixture.active { local.follow(in: store) }
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
                // Shireworks Kit: crashes and Help › Report a Bug… (below)
                // filed as issues in the Info.plist's ShireworksRepository,
                // and Shireworks' offers of an update answered as
                // VisorUpdates registered (CI's builds to publish carry the
                // keys: tools/shared_sign_in, tools/signing).
                .shireworks()
        }
        .handlesExternalEvents(matching: ["*"])
        // Shown at a person's launch: a menu bar app's window is not, unless
        // asked. launchd's, at login and after a crash, keeps to the menu
        // bar (MacAppInstance.showsWindow).
        .defaultLaunchBehavior(MacAppInstance.showsWindow ? .presented : .suppressed)
        // The sidebar, and a thread about as wide as the transcript grows.
        .defaultSize(width: 1200, height: 820)
        .commands {
            // ⌘Q closes the window, back to the menu bar: quitting ends the
            // agents of the server in the app, which only the menu's Quit
            // Visor does.
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
            // Help › Report a Bug… (⌥⌘B).
            ShakeKitCommands()
        }
        Settings {
            ServerSettingsPane(local: local)
        }
        // Report a Bug… with every window closed (the menu's button,
        // VisorMenu, or Help's command): Shireworks Kit's own window.
        ShakeKitReportWindow(repository: Self.reportRepository)
    }
}
