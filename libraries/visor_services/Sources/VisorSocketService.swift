/// A WebSocket per connection, by id. `next` suspends until the socket
/// has an event and returns it as one line: "open", "message <text>",
/// "close <reason>" or "error <reason>"; it throws once the socket is gone.
@MainActor
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
