// The app's side of push notifications on iOS: the token the system gives
// and the notification the user opens, handed to the shared handler (which
// the client listens to). The one place the app meets UIKit's application
// delegate, which is where iOS delivers both.

#if os(iOS)
import UIKit
import UserNotifications
import VisorServices

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // A development build's token is for APNs's sandbox (the app is
        // signed with a development profile: aps-environment development).
        VisorNotificationHandler.shared.didRegister(token: token, platform: "ios", environment: "sandbox",
                                                    topic: Bundle.main.bundleIdentifier ?? "")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// The user opened a notification: its session, on its computer.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        VisorNotificationHandler.shared.didOpen(Self.data(of: response.notification))
    }

    /// With the app in front: shown as a banner, which opens its session
    /// when tapped — unless it is about the session on screen, whose thread
    /// already says it.
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
