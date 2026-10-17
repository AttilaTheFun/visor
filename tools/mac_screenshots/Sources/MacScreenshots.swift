// The Mac client on the screenshot fixture, as its window shows it, saved
// as a picture: the screen named on the command line opened, a moment for
// the thread to settle, the window captured (`screencapture`), and out.

import AppKit
import SwiftUI
import VisorClient
import VisorServices
import VisorUI

@main
struct MacScreenshots: App {
    @State private var store: VisorStore

    init() {
        let arguments = CommandLine.arguments.dropFirst()
        let screen = arguments.first ?? "chat"
        let appearance = arguments.dropFirst(2).first ?? "dark"
        // The fixture, by the settings the app reads it from: registered,
        // so nothing is written down.
        UserDefaults.standard.register(defaults: ["visor.fixture": "snapshot", "visor.fixture.screen": screen,
                                                  "visor.fixture.appearance": appearance])
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             deviceName: "Mac", appVersion: "0.35", platformName: "macOS")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        _store = State(initialValue: VisorStore())
        let out = arguments.dropFirst().first ?? "/tmp/visor-mac-\(screen).png"
        Task { @MainActor in
            NSApplication.shared.activate()
            try? await Task.sleep(for: .seconds(6))
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-l\(window.windowNumber)", "-o", "-x", out]
                try? capture.run()
                capture.waitUntilExit()
            }
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 780)
    }
}
