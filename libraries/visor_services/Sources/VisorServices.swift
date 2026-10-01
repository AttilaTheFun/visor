// The services a host injects into the client (docs/wasm_di.md in swift_ffi,
// the same shape as Isomer's platform services): a WebSocket the client
// drives by id, HTTP requests, a settings store for the saved computers,
// and — where the host has them — notifications and a home screen widget.
// Nothing else crosses the boundary; async methods suspend in the guest
// and the host answers when it has something.

/// A WebSocket per connection, by id. `next` suspends until the socket
/// has an event and returns it as one line: "open", "message <text>",
/// "close <reason>" or "error <reason>"; it throws once the socket is gone.
public protocol VisorSocketService {
    /// Opens a socket to `url` (ws:// or wss://) and returns its id.
    func open(url: String) -> Int32
    func send(id: Int32, text: String)
    func disconnect(id: Int32)
    func next(id: Int32) async throws -> String
    /// Suspends for a while (the reconnect backoff). The host's timer: the
    /// wasm executor has none of its own, so `Task.sleep` is not portable.
    func delay(milliseconds: Int32) async
}

/// One HTTPS request (the REST side of the protocol). Returns the body for
/// a 2xx status; throws with the status and body otherwise.
public protocol VisorHTTPService {
    func request(method: String, url: String, body: String, authorization: String) async throws -> String
    /// The HTTP status behind an error `request` threw, when it was one
    /// (a 401 is how a computer asks for a password).
    func status(of error: Error) -> Int?
}

public extension VisorHTTPService {
    /// A host whose errors read "HTTP <status>: …" needs nothing more.
    func status(of error: Error) -> Int? {
        // The standard library alone: this builds for the browser, whose
        // Foundation has no `range(of:)`.
        let text = Array("\(error)")
        let marker = Array("HTTP ")
        guard text.count >= marker.count else { return nil }
        for start in 0...(text.count - marker.count) where Array(text[start..<start + marker.count]) == marker {
            return Int(String(text[(start + marker.count)...].prefix { $0.isNumber }))
        }
        return nil
    }
}

/// Small persistent settings (UserDefaults on Apple, localStorage on the
/// web): `get` returns "" for an unset key. Secrets (a computer's password)
/// go through `secret`/`setSecret`: the keychain on Apple; a host with no
/// keychain keeps them with the rest.
public protocol VisorSettingsService {
    func get(key: String) -> String
    func set(key: String, value: String)
    func secret(key: String) -> String
    func setSecret(key: String, value: String)
}

public extension VisorSettingsService {
    func secret(key: String) -> String { get(key: "secret." + key) }
    func setSecret(key: String, value: String) { set(key: "secret." + key, value: value) }
}

/// Tells the user something happened: local notifications where the host
/// has them (iOS). A host without them installs none, and nothing is said.
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

/// A notification the user opened: which session, on which computer (by
/// the address the client knows it at).
public struct NotificationTarget: Sendable, Equatable {
    public let computer: String
    public let session: String
    public init(computer: String, session: String) {
        self.computer = computer
        self.session = session
    }
}

/// Where a host relays what its system says about notifications — the push
/// token it was given, a notification the user opened — and where the
/// client hears it. One for the app; the host calls in, the client
/// listens.
public final class VisorNotificationHandler: @unchecked Sendable {
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

/// Somewhere outside the app that shows the latest sessions: the home
/// screen's widget on iOS. Given the latest as JSON whenever it changes; a
/// host without one installs none.
public protocol VisorWidgetService {
    func publish(_ json: String)
}

/// Where the client reads the services its host installed
/// (`installVisorServices`). Absent services are nil.
public enum VisorHost {
    public nonisolated(unsafe) static var socket: (any VisorSocketService)?
    public nonisolated(unsafe) static var http: (any VisorHTTPService)?
    public nonisolated(unsafe) static var settings: (any VisorSettingsService)?
    public nonisolated(unsafe) static var notifications: (any VisorNotificationService)?
    public nonisolated(unsafe) static var widget: (any VisorWidgetService)?
}

/// Hands the client its services. An app calls this once, before it makes
/// a store; a host that carries the client somewhere else (a browser, an
/// Android app) installs its own.
public func installVisorServices(socket: any VisorSocketService, http: any VisorHTTPService, settings: any VisorSettingsService,
                                 notifications: (any VisorNotificationService)? = nil, widget: (any VisorWidgetService)? = nil) {
    VisorHost.socket = socket
    VisorHost.http = http
    VisorHost.settings = settings
    VisorHost.notifications = notifications
    VisorHost.widget = widget
}
