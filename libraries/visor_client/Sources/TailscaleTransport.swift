import VisorProtocol
import VisorServices

/// The Tailscale road, over the host's socket and HTTP services.
public final class TailscaleTransport: HostTransport {
    private var socketID: Int32?
    private var reader: Task<Void, Never>?

    public init() {}

    public func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void) {
        disconnect()
        // What went wrong is said after `connect` returns, as an event from
        // the socket would be.
        guard let socket = VisorHost.socket else {
            Task { onEvent(.closed("No socket service on this host")) }
            return
        }
        let id = socket.open(url: "wss://\(config.host)")
        guard id >= 0 else {
            Task { onEvent(.closed("Bad address")) }
            return
        }
        socketID = id
        reader = Task { [weak self] in
            // Events arrive one at a time; the loop ends when the socket is gone.
            while !Task.isCancelled {
                do {
                    let event = try await socket.next(id: id)
                    guard let self, self.socketID == id else { return }
                    if event == "open" {
                        onEvent(.opened)
                    } else if event.hasPrefix("message ") {
                        onEvent(.message(String(event.dropFirst(8))))
                    } else if event.hasPrefix("close ") || event.hasPrefix("error ") {
                        self.socketID = nil
                        onEvent(.closed(String(event.split(separator: " ", maxSplits: 1).last ?? "")))
                        return
                    }
                } catch {
                    guard let self, self.socketID == id else { return }
                    self.socketID = nil
                    onEvent(.closed("connection lost"))
                    return
                }
            }
        }
    }

    public func send(_ text: String) {
        guard let socketID else { return }
        VisorHost.socket?.send(id: socketID, text: text)
    }

    public func disconnect() {
        reader?.cancel()
        reader = nil
        if let socketID { VisorHost.socket?.disconnect(id: socketID) }
        socketID = nil
    }

    public func call(_ method: String, _ path: String, body: String, config: HostConfig) async throws -> String {
        guard let http = VisorHost.http else { throw TransportError.noHTTP }
        return try await http.request(method: method, url: "https://\(config.host)/api" + path, body: body, authorization: config.password)
    }

    public func status(of error: Error) -> Int? { VisorHost.http?.status(of: error) }

    public func delay(milliseconds: Int32) async {
        await VisorHost.socket?.delay(milliseconds: milliseconds)
    }
}
