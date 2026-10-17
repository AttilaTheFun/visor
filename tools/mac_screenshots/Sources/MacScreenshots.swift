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
            let windows = NSApplication.shared.windows
            FileHandle.standardError.write(Data("windows: \(windows.map { "\($0.windowNumber) visible=\($0.isVisible) \($0.frame)" })\n".utf8))
            if let window = windows.first(where: { $0.isVisible }) {
                Self.capture(["-l\(window.windowNumber)", "-o", "-x", out])
            }
            // No picture of the window: the whole screen, to see why.
            if !FileManager.default.fileExists(atPath: out) {
                Self.capture(["-x", out.replacingOccurrences(of: ".png", with: "-screen.png")])
            }
            NSApplication.shared.terminate(nil)
        }
    }

    /// `screencapture` with these arguments, saying how it went.
    static func capture(_ arguments: [String]) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = arguments
        do {
            try capture.run()
            capture.waitUntilExit()
            FileHandle.standardError.write(Data("screencapture \(arguments.joined(separator: " ")): \(capture.terminationStatus)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("screencapture failed: \(error)\n".utf8))
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
