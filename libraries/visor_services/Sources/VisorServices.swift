// The services a host injects into the client (docs/wasm_di.md in swift_ffi,
// the same shape as universal_ui's platform services): a WebSocket the
// client drives by id, and a settings store for the saved computers.
// Nothing else crosses the boundary; async methods suspend in the guest
// and the host answers when it has something.


/// The keys of the host-injected dependency dictionary.

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
        let text = "\(error)"
        guard let range = text.range(of: "HTTP ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

/// Small persistent settings (UserDefaults on Apple, localStorage on the
/// web): `get` returns "" for an unset key.
public protocol VisorSettingsService {
    func get(key: String) -> String
    func set(key: String, value: String)
}

/// Where the client reads the injected services — resolved lazily, once,
/// from the dependency dictionary. Absent services are nil.
public enum VisorHost {
    public nonisolated(unsafe) static var socket: (any VisorSocketService)?
    public nonisolated(unsafe) static var http: (any VisorHTTPService)?
    public nonisolated(unsafe) static var settings: (any VisorSettingsService)?
}

/// Hands the client its services. An app calls this once, before it makes
/// a store; a host that carries the client somewhere else (a browser, an
/// Android app) installs its own.
public func installVisorServices(socket: any VisorSocketService, http: any VisorHTTPService, settings: any VisorSettingsService) {
    VisorHost.socket = socket
    VisorHost.http = http
    VisorHost.settings = settings
}
