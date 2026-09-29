// Local notifications on iOS: a turn finished, a goal done, an agent
// waiting for approval. Said while the app runs or has just gone to the
// background; iOS suspends it soon after, and what happens then is told
// when the app is next opened.

#if os(iOS)
import UserNotifications

public final class NativeVisorNotificationService: VisorNotificationService, @unchecked Sendable {
    public init() {}

    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = String(id.split(separator: "/").prefix(2).joined(separator: "/"))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
#endif
