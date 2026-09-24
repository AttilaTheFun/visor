// How a client reaches a computer. The protocol is the same whatever is on
// the other end; what differs is the road — a Mac's Tailscale endpoint
// here, a company's own service hosting sandboxed sessions in a fork. A
// backend names the road and makes the transport that drives it; the
// registry is where a fork adds its own.

import VisorProtocol
import VisorServices

/// What comes back over the live channel.
public enum TransportEvent: Sendable {
    case opened
    case message(String)
    case closed(String)
}

/// A live channel carrying the protocol's envelopes both ways, and one-shot
/// calls to the computer's REST side. One transport per computer.
public protocol HostTransport: AnyObject {
    /// Opens the live channel; events arrive on the main actor. A transport
    /// that cannot open reports `.closed` with the reason.
    func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void)
    func send(_ text: String)
    func disconnect()
    /// One request to the REST side: the answer's body, or a throw.
    func call(_ method: String, _ path: String, body: String, config: HostConfig) async throws -> String
    /// The HTTP status behind what `call` threw, when it was one.
    func status(of error: Error) -> Int?
    /// A pause, for the reconnect backoff.
    func delay(milliseconds: Int32) async
}

public extension HostTransport {
    func status(of error: Error) -> Int? { nil }
}

/// A kind of computer to connect to: its transport, and how the connect
/// form names the two things it asks for.
public protocol Backend: Sendable {
    var id: String { get }
    var title: String { get }
    var hostFieldTitle: String { get }
    var hostPlaceholder: String { get }
    var passwordFieldTitle: String { get }
    /// A sentence under the form.
    var help: String { get }
    func makeTransport() -> any HostTransport
}

/// The backends this build knows. Tailscale is the one shipped; a fork
/// registers its own at launch, before the store is made.
public enum Backends {
    nonisolated(unsafe) private static var registry: [any Backend] = [TailscaleBackend()]

    public static var all: [any Backend] { registry }

    public static func register(_ backend: any Backend) {
        registry.removeAll { $0.id == backend.id }
        registry.append(backend)
    }

    public static func backend(for id: String) -> (any Backend)? {
        registry.first { $0.id == id }
    }

    /// The transport for a computer; an unknown backend gets the first.
    static func transport(for config: HostConfig) -> any HostTransport {
        (backend(for: config.backend) ?? registry[0]).makeTransport()
    }
}

/// A Mac running the menu bar app behind its Tailscale Serve endpoint:
/// wss:// on 443 for the live channel, https://…/api for calls, the
/// password as a bearer token.
public struct TailscaleBackend: Backend {
    public let id = "tailscale"
    public let title = "Tailscale"
    public let hostFieldTitle = "Tailscale name"
    public let hostPlaceholder = "my-mac.tail1234.ts.net"
    public let passwordFieldTitle = "Password (if asked)"
    public let help = "The Visor menu bar app on the Mac gives a connection code to copy, and a QR code to scan, holding its Tailscale name and password. Connections are HTTPS through Tailscale."
    public init() {}
    public func makeTransport() -> any HostTransport { TailscaleTransport() }
}

/// The Tailscale road, over the host's socket and HTTP services.
public final class TailscaleTransport: HostTransport {
    private var socketID: Int32?
    private var reader: Task<Void, Never>?

    public init() {}

    public func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void) {
        disconnect()
        guard let socket = VisorHost.socket else {
            Task { @MainActor in onEvent(.closed("No socket service on this host")) }
            return
        }
        let id = socket.open(url: "wss://\(config.host)")
        guard id >= 0 else {
            Task { @MainActor in onEvent(.closed("Bad address")) }
            return
        }
        socketID = id
        reader = Task { @MainActor [weak self] in
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

public enum TransportError: Error { case noHTTP }
