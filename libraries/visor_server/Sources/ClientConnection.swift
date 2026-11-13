// One client's WebSocket, as the server holds it.

import Foundation
import VisorProtocol
import VisorSystem

/// One client's WebSocket.
@MainActor
final class ClientConnection {
    private let socket: WebSocketConnection
    var authenticated = false
    /// Whether it came on a connection only this user could open (the
    /// socket file an SSH client reaches): its login needs no password.
    var trusted = false
    /// The client id its login gave (a Visor client's own), for the log.
    var clientID: String?
    /// Its upgrade's headers (names in lower case): what a front said of it.
    var headers: [String: String] = [:]
    /// Who it is, where a front named them (FrontTrust): their id.
    var user: String?
    /// An agent's one request (the Visor MCP server's, the permission
    /// shim's), not a client: the log leaves it out.
    var agent = false
    /// When it connected, for how long it stayed.
    let since = Date()
    var onMessage: ((Envelope) -> Void)?
    var onClose: (() -> Void)?

    init(stream: any ByteStream, received: Data = Data()) {
        socket = WebSocketConnection(stream: stream, received: received)
    }

    /// What it says is taken as it is said, in order.
    func start() {
        socket.onText = { [weak self] text in
            if let envelope = Envelope.decode(text) { self?.onMessage?(envelope) }
        }
        socket.onClose = { [weak self] in self?.onClose?() }
        socket.start()
    }

    func send(_ envelope: Envelope) {
        socket.send(text: envelope.encoded())
    }

    /// Says one last thing and closes once it has gone out.
    func sendLast(_ envelope: Envelope) {
        socket.sendLast(text: envelope.encoded())
    }

    func close() {
        socket.close()
    }
}
