import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisorProtocol
import VisorServer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The server runs from launch, whether or not the menu is ever
    /// opened — once it has a password. Without one, Settings opens.
    func applicationDidFinishLaunching(_ notification: Notification) {
        VisorServer.shared.start()
        if VisorServer.shared.password.isEmpty { Self.openSettings() }
    }

    /// The agents go before the app does: quitting waits for them. The
    /// app's own Quit ends them first (`VisorServer.quit`); this is for a
    /// quit that comes from outside (logging out, another app asking).
    /// While it waits, AppKit runs the run loop, and the task below runs
    /// with it — but not if the quit was asked for from inside a task on
    /// the main actor, which is why the app's own code calls `quit`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !VisorServer.shared.agentsEnded else { return .terminateNow }
        Task {
            await VisorServer.shared.endAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens Settings in front of every other app's windows. The app has no
    /// Dock icon, and opening a window does not bring it forward: Settings
    /// opened behind whatever was in use, to be dug out from under it.
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's Settings scene answers the standard action.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsForward()
    }

    /// The Settings window, once SwiftUI has made it (a moment after the
    /// action), made key and ordered in front of other apps' windows.
    private static func bringSettingsForward() {
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }),
                   window.isVisible {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
