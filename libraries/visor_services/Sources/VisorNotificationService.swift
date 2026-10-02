/// Tells the user something happened: local notifications where the host
/// has them (iOS). A host without them installs none, and nothing is said.
@MainActor
public protocol VisorNotificationService {
    /// Asks, once, whether the app may notify the user.
    func requestPermission()
    /// Says something now. A later notification with the same `id`
    /// replaces this one.
    func notify(id: String, title: String, body: String)
    /// Asks the system for this device's push token: it comes back through
    /// `VisorNotificationHandler.shared.didRegister`.
    func registerForRemoteNotifications()
}

public extension VisorNotificationService {
    /// A host without pushes: nothing to register.
    func registerForRemoteNotifications() {}
}
