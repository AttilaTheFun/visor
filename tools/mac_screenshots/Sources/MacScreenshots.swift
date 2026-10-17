// The Mac client on the screenshot fixture, as its window shows it, saved
// as a picture: the screen named on the command line opened, a moment for
// the thread to settle, the window captured (`screencapture`), and out.
// The window is the app's own content in a window made here (an executable
// outside a bundle gets none from a scene), its toolbar and title bridged
// from SwiftUI as the app's are.

import AppKit
import SwiftUI
import VisorClient
import VisorServices
import VisorUI

@main
@MainActor
enum MacScreenshots {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let screen = arguments.first ?? "chat"
        let out = arguments.count > 1 ? arguments[1] : "/tmp/visor-mac-\(screen).png"
        let appearance = arguments.count > 2 ? arguments[2] : "dark"
        // The fixture, by the settings the app reads it from: registered,
        // so nothing is written down.
        UserDefaults.standard.register(defaults: ["visor.fixture": "snapshot", "visor.fixture.screen": screen,
                                                  "visor.fixture.appearance": appearance])
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             deviceName: "Mac", appVersion: "0.35", platformName: "macOS")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        let store = VisorStore()
        let window = UnconstrainedWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                         backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: VisorRootView().environment(store))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = hosting
        window.title = "Visor"
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.makeKeyAndOrderFront(nil)
        app.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            FileHandle.standardError.write(Data("window \(window.windowNumber) visible=\(window.isVisible) \(window.frame)\n".utf8))
            capture(["-l\(window.windowNumber)", "-o", "-x", out])
            // No picture of the window: the whole screen, to see why.
            if !FileManager.default.fileExists(atPath: out) {
                capture(["-x", out.replacingOccurrences(of: ".png", with: "-screen.png")])
            }
            app.terminate(nil)
        }
        app.run()
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
}

/// A window kept at the size asked for, though the screen it is on (CI's,
/// 1024 × 768) is smaller: the picture is of the window, not the screen.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
