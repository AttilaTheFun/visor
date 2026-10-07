// The Mac client's @main, on the shared host sources.

import SwiftUI
import VisorClient
import VisorServices
import VisorUI

#if os(macOS)
@main
struct VisorMacApp: App {
    @StateObject private var store: VisorStore
    /// Where the system hands over the push token and the notification
    /// the user opened (MacPushDelegate).
    @NSApplicationDelegateAdaptor(MacPushDelegate.self) private var pushDelegate

    init() {
        Self.adoptFormerApp()
        // The host's services first: the store connects through them.
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             notifications: NativeVisorNotificationService(), ssh: NativeVisorSSHService(), network: NativeVisorNetworkService())
        if !VisorFixture.active {
            // (The push token is asked for once launched: MacPushDelegate.)
            VisorHost.notifications?.requestPermission()
        }
        _store = StateObject(wrappedValue: VisorStore())
    }

    /// The bundle id this app had before: its saved computers and its
    /// cache are taken over the first time this build runs.
    static let formerBundleID = "com.LoganShire.Visor.macOS"

    static func adoptFormerApp() {
        guard Bundle.main.bundleIdentifier != formerBundleID,
              UserDefaults.standard.string(forKey: "visor.hosts") == nil,
              let former = UserDefaults(suiteName: formerBundleID) else { return }
        for (key, value) in former.dictionaryRepresentation() where key.hasPrefix("visor.") {
            UserDefaults.standard.set(value, forKey: key)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let current = Bundle.main.bundleIdentifier {
            let target = base.appendingPathComponent(current)
            let source = base.appendingPathComponent(formerBundleID)
            if !FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 480)
                // visor://connect?code=… — a connection code from a QR
                // code or a link adds that computer.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
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
        }
    }
}
#endif
