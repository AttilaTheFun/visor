/// Where a host relays what its system says about notifications — the push
/// token it was given, a notification the user opened — and where the
/// client hears it. One for the app; the host calls in, the client
/// listens.
@MainActor
public final class VisorNotificationHandler {
    public static let shared = VisorNotificationHandler()

    /// The device's push token, hex, once the system has given one.
    public private(set) var token: String?
    /// Which kind of device the token is for: "ios", "macos".
    public private(set) var platform = ""
    /// Which push service the token belongs to: "sandbox" for development
    /// builds, "production" for release ones.
    public private(set) var environment = ""
    /// The app the token is for (its bundle id: APNs's topic).
    public private(set) var topic = ""
    /// Told when a token arrives (the client hands it to each computer).
    public var onToken: (() -> Void)?
    /// The session on screen, if any: a notification about it, arriving
    /// while the app is in front, is not shown (the thread says it).
    public var viewing: NotificationTarget?

    /// Whether a notification arriving with the app in front is shown: yes,
    /// unless it is about the session on screen.
    public func presents(_ data: [String: String]) -> Bool {
        guard let viewing else { return true }
        return !(data["computer"] == viewing.computer && data["session"] == viewing.session)
    }

    /// Told which session a notification the user opened is about. A tap
    /// that launched the app waits here until someone listens.
    public var onOpen: ((NotificationTarget) -> Void)? {
        didSet {
            if let pending, let onOpen { self.pending = nil; onOpen(pending) }
        }
    }
    private var pending: NotificationTarget?

    public init() {}

    public func didRegister(token: String, platform: String, environment: String, topic: String) {
        self.token = token
        self.platform = platform
        self.environment = environment
        self.topic = topic
        onToken?()
    }

    /// A notification the user opened, by the data it carried: "computer"
    /// and "session". Anything else is ignored.
    public func didOpen(_ data: [String: String]) {
        guard let computer = data["computer"], let session = data["session"] else { return }
        let target = NotificationTarget(computer: computer, session: session)
        if let onOpen { onOpen(target) } else { pending = target }
    }
}
