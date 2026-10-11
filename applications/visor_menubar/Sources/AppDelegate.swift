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
    /// Dock icon, and macOS does not bring such an app forward, however it
    /// asks (activating it, ordering the window front: tried in 0.30 (1),
    /// and Settings still opened behind): while Settings is open the app is
    /// a regular one, Dock icon and all, and goes back to the menu bar
    /// alone when Settings closes.
    static func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // SwiftUI's Settings scene answers the standard action.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsForward()
    }

    /// The Settings window, once SwiftUI has made it (a moment after the
    /// action): made key, in front, and watched for its closing.
    private static func bringSettingsForward() {
        Task { @MainActor in
            for _ in 0..<40 {
                // The only titled window the app has (the menu's is not).
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    await backToTheMenuBar(when: window)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // No window came: nothing to keep a Dock icon for.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// The menu bar alone again once `window` closes.
    private static func backToTheMenuBar(when window: NSWindow) async {
        for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window) {
            NSApp.setActivationPolicy(.accessory)
            return
        }
    }
}
