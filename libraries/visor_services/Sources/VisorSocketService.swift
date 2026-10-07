/// A WebSocket per connection, by id. `next` suspends until the socket
/// has an event and returns it as one line: "open", "message <text>",
/// "close <reason>" or "error <reason>"; it throws once the socket is gone.
@MainActor
public protocol VisorSocketService {
    /// Opens a socket to `url` (ws:// or wss://) and returns its id.
    func open(url: String) -> Int32
    /// The same, with headers on the opening request (what the
    /// authenticator gives; a front that checks them sees them). A host
    /// that cannot send them (a browser) opens without.
    func open(url: String, headers: [String: String]) -> Int32
    func send(id: Int32, text: String)
    func disconnect(id: Int32)
    func next(id: Int32) async throws -> String
    /// Suspends for a while (the reconnect backoff). The host's timer: the
    /// wasm executor has none of its own, so `Task.sleep` is not portable.
    func delay(milliseconds: Int32) async
    /// Whether the host's sockets die when the app leaves the front for
    /// the background (an iPhone's do): the client then opens them afresh
    /// on coming back rather than asking whether they are still there.
    var dropsInBackground: Bool { get }
}

public extension VisorSocketService {
    var dropsInBackground: Bool { false }
    func open(url: String, headers: [String: String]) -> Int32 { open(url: url) }
}
