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
        VisorNotificationHandler.shared.didRegister(token: token, platform: "ios", environment: Self.pushEnvironment,
                                                    topic: Bundle.main.bundleIdentifier ?? "")
    }

    /// Which of APNs's services the token is for, as the app was signed:
    /// "sandbox" under a development profile (aps-environment development),
    /// "production" under any other, and from the App Store, where no
    /// profile is embedded.
    static var pushEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        // The profile is a signed envelope around a property list; its
        // entitlements are plain text inside.
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { return "production" }
        return text[open.upperBound..<close.lowerBound] == "development" ? "sandbox" : "production"
    }

    /// A push arrived, shown or silent, with the app in front, behind or
    /// woken for it: what it says of its session's state goes to the
    /// widget.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String { data[key] = value }
        }
        return WidgetFeed().take(push: data) ? .newData : .noData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Visor: no push token: %@", String(describing: error))
    }

    /// The user opened a notification: its session, on its computer.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = Self.data(of: response.notification)
        await VisorNotificationHandler.shared.didOpen(data)
    }

    /// With the app in front: shown as a banner, which opens its session
    /// when tapped — unless it is about the session on screen, whose thread
    /// already says it.
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
#endif
