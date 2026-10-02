// The services a host injects into the client (docs/wasm_di.md in swift_ffi,
// the same shape as Isomer's platform services): a WebSocket the client
// drives by id, HTTP requests, a settings store for the saved computers,
// and — where the host has them — notifications and a home screen widget.
// Nothing else crosses the boundary; async methods suspend in the guest
// and the host answers when it has something.
//
// The client lives on the main actor, and so do the services it drives
// from there. HTTP is the exception: a request is the same from anywhere,
// and its answer is read off the main actor.

/// Where the client reads the services its host installed
/// (`installVisorServices`). Absent services are nil.
@MainActor
public enum VisorHost {
    public static var socket: (any VisorSocketService)?
    public static var http: (any VisorHTTPService)?
    public static var settings: (any VisorSettingsService)?
    public static var notifications: (any VisorNotificationService)?
    public static var widget: (any VisorWidgetService)?
}

/// Hands the client its services. An app calls this once, before it makes
/// a store; a host that carries the client somewhere else (a browser, an
/// Android app) installs its own.
@MainActor
public func installVisorServices(socket: any VisorSocketService, http: any VisorHTTPService, settings: any VisorSettingsService,
                                 notifications: (any VisorNotificationService)? = nil, widget: (any VisorWidgetService)? = nil) {
    VisorHost.socket = socket
    VisorHost.http = http
    VisorHost.settings = settings
    VisorHost.notifications = notifications
    VisorHost.widget = widget
}
