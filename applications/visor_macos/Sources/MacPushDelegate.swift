// The Mac client's side of push notifications: the token the system gives
// and the notification the user opens, handed to the shared handler (which
// the client listens to). AppKit's application delegate is where macOS
// delivers both.

#if os(macOS)
import AppKit
import UserNotifications
import VisorClient
import VisorServices

final class MacPushDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Once launched, when AppKit delivers the token to this delegate:
        // asked any earlier, the answer can go nowhere.
        if !VisorFixture.active { NSApplication.shared.registerForRemoteNotifications() }
    }

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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        VisorNotificationHandler.shared.didOpen(Self.data(of: response.notification))
    }

    /// With the app in front: shown, unless it is about the session on screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        VisorNotificationHandler.shared.presents(Self.data(of: notification)) ? [.banner, .list, .sound] : []
    }

    static func data(of notification: UNNotification) -> [String: String] {
        var data: [String: String] = [:]
        for (key, value) in notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { data[key] = value }
        }
        return data
    }
}
#endif
