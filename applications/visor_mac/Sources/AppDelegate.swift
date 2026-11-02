// Visor's application delegate on the Mac: the server's life (started at
// launch, its agents ended before a quit, as Visor Server did), the
// client's pushes (the token and the notifications, as the Mac client did),
// and the Dock icon, which the app shows only while one of its windows is
// open: it is a menu bar app first.

import AppKit
import SwiftUI
import UserNotifications
import VisorClient
import VisorServer
import VisorServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The server runs from launch, whether or not a window or the menu
        // is ever opened, once it has a password. Without one, Settings
        // opens over the window when it shows (SceneOpeners).
        VisorServer.shared.start()
        UNUserNotificationCenter.current().delegate = self
        // Once launched, when AppKit delivers the token to this delegate:
        // asked any earlier, the answer can go nowhere.
        if !VisorFixture.active { NSApplication.shared.registerForRemoteNotifications() }
        Self.followWindows()
    }

    /// The agents go before the app does: quitting waits for them. The
    /// menu's Quit Visor ends them first (`VisorServer.quit`); this is for
    /// a quit that comes from outside (logging out, another app asking).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !VisorServer.shared.agentsEnded else { return .terminateNow }
        Task {
            await VisorServer.shared.endAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opened again (from the Finder, the Dock, Spotlight) with no window
    /// showing: Visor's window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let open = Self.openWindow { Self.show(window: VisorMacApp.mainWindow, with: open) }
        return true
    }

    // MARK: Windows and the Dock icon

    /// SwiftUI's own ways to the window and Settings, as a view last had
    /// them (SceneOpeners).
    private static var openWindow: OpenWindowAction?
    private static var openSettingsAction: OpenSettingsAction?

    static func keep(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        Self.openWindow = openWindow
        openSettingsAction = openSettings
    }

    /// The Dock icon while a window of the app's own is open, and the menu
    /// bar alone when the last one closes. An app with no Dock icon is not
    /// brought forward by macOS, however it asks (Visor Server 0.30), so a
    /// window is shown with the app a regular one.
    static func followWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.matchWindows() }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // Which window, by identity alone: the window itself stays on
            // the main actor.
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { Self.matchWindows(closing: closing) }
        }
        // The window SwiftUI opens at launch is in front, with the app.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !windows().isEmpty {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        }
    }

    /// The app's own windows that are open: titled ones (the menu bar's
    /// menu is not).
    private static func windows(but closing: ObjectIdentifier? = nil) -> [NSWindow] {
        NSApp.windows.filter { ObjectIdentifier($0) != closing && $0.isVisible && $0.styleMask.contains(.titled) }
    }

    private static func matchWindows(closing: ObjectIdentifier? = nil) {
        let wanted: NSApplication.ActivationPolicy = windows(but: closing).isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// A window of the app's, in front of every other app's.
    static func show(window id: String, with openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate()
    }

    /// ⌘Q in Visor's window: the windows closed and the app back in the
    /// menu bar. Quitting ends the server's agents, so only the menu's Quit
    /// Visor does that.
    static func backToTheMenuBar() {
        for window in windows() { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opens Settings in front of every other app's windows, as Visor Server
    /// did: the app a regular one while it is open.
    static func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let open = openSettingsAction {
            open()
        } else {
            // Before any view has shown: the standard action, which SwiftUI's
            // Settings scene answers where it still does.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Task { @MainActor in
            for _ in 0..<40 {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.isKeyWindow }) {
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            matchWindows()
        }
    }

    // MARK: Pushes

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Signed with Developer ID: its token is for APNs's production
        // service (aps-environment production).
        VisorNotificationHandler.shared.didRegister(token: token, platform: "macos", environment: "production",
                                                    topic: Bundle.main.bundleIdentifier ?? "")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Visor: no push token: %@", String(describing: error))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = Self.data(of: response.notification)
        await VisorNotificationHandler.shared.didOpen(data)
    }

    /// With the app in front: shown, unless it is about the session on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let data = Self.data(of: notification)
        return await VisorNotificationHandler.shared.presents(data) ? [.banner, .list, .sound] : []
    }

    /// What a notification carries, as the handler takes it. The system
    /// calls the delegate off the main actor; only this crosses to it.
    nonisolated static func data(of notification: UNNotification) -> [String: String] {
        var data: [String: String] = [:]
        for (key, value) in notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { data[key] = value }
        }
        return data
    }
}
