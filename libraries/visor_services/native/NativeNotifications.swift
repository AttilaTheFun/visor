// Notifications on iOS and the Mac: a turn finished, a goal done, an agent
// waiting for approval. Said while the app runs or has just gone to the
// background; iOS suspends it soon after, and what happens then is told
// when the app is next opened.

#if os(iOS) || os(macOS)
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UserNotifications

public final class NativeVisorNotificationService: VisorNotificationService, @unchecked Sendable {
    public init() {}

    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func registerForRemoteNotifications() {
        #if os(iOS)
        Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        #else
        Task { @MainActor in NSApplication.shared.registerForRemoteNotifications() }
        #endif
    }

    public func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let parts = id.split(separator: "/").map(String.init)
        content.threadIdentifier = parts.prefix(2).joined(separator: "/")
        // Where to go when it is opened, as a push says it.
        if parts.count >= 2 { content.userInfo = ["computer": parts[0], "session": parts[1]] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
#endif
