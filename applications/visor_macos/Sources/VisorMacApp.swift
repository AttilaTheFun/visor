// Visor Client's @main, the Mac client's, on the shared host sources.

import ShakeKit
import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices
import VisorUI

#if os(macOS)
@main
struct VisorMacApp: App {
    @State private var store: VisorStore
    /// Where the system hands over the push token and the notification
    /// the user opened (MacPushDelegate).
    @NSApplicationDelegateAdaptor(MacPushDelegate.self) private var pushDelegate

    /// This app's version and build ("0.31 (8)").
    static var bundleVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return VersionTitle.of(version: short, build: build)
    }

    init() {
        // The host's services first: the store connects through them.
        // Visor Client is sandboxed (applications/visor_macos/BUILD.bazel):
        // its secrets in its own keychain group where the build has one
        // (ClientKeychain), and no SSH, whose tunnel listens on 127.0.0.1,
        // which the sandbox refuses a client (no network.server): its
        // computers are reached over HTTP and HTTPS alone. Nothing of a
        // server's either: no socket file, launchd job, ~/.visor or ~/.ssh.
        // (Nor what the client kept before 0.46, as com.LoganShire.Visor.macOS:
        // outside its container, the sandbox doesn't read it.)
        let settings = NativeVisorSettingsService(keychainGroup: ClientKeychain.ownGroup())
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: settings,
                             notifications: NativeVisorNotificationService(), ssh: nil, network: NativeVisorNetworkService(),
                             dictation: NativeVisorDictationService(), deviceName: Host.current().localizedName ?? "",
                             appVersion: Self.bundleVersion, platformName: "macOS")
        // The sandbox reads the files the person picks and writes none: an
        // exported session is shared, not saved.
        VisorHost.savesFiles = false
        if !VisorFixture.active {
            // (The push token is asked for once launched: MacPushDelegate.)
            VisorHost.notifications?.requestPermission()
        }
        let store = VisorStore()
        VisorHost.forgetEverything = { ForgetEverything.run(store: store, settings: settings) }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                // The sidebar at its ideal (300: AppKit lays the columns out
                // at their ideal widths), the detail's least (440) and
                // Settings' inspector at its ideal (320), with room: at 980
                // the detail got 360 and the chat ran under its composer.
                .frame(minWidth: 1_100, minHeight: 480)
                // visor://connect?code=… — a connection code from a QR
                // code or a link adds that computer; visor://sign-in shows
                // a computer's settings.
                .onOpenURL { url in store.open(url.absoluteString) }
                // Every link to the window that is open, brought forward,
                // rather than a new window for each.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Help › Report a Bug… (below) files one in this
                // repository, as an issue (ShakeKit: on in every build, by
                // its Info.plist).
                .shakeToReport(repository: "AttilaTheFun/visor")
        }
        .handlesExternalEvents(matching: ["*"])
        // The sidebar, and a thread about as wide as the transcript grows.
        .defaultSize(width: 1200, height: 820)
        // The Mac keeps the computers in its menu bar; a phone and the web
        // reach the same sheet from a bar item.
        .commands {
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
    }
}
#endif
