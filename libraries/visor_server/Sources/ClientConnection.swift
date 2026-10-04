// One client's WebSocket, as the server holds it.

import Foundation
import VisorProtocol

/// One client's WebSocket.
@MainActor
final class ClientConnection {
    private let socket: WebSocketConnection
    var authenticated = false
    /// Which client this is, as it named itself at login: whose window a
    /// terminal may be drawn for.
    var clientID = ""
    var onMessage: ((Envelope) -> Void)?
    var onClose: (() -> Void)?

    init(stream: any ByteStream) {
        socket = WebSocketConnection(stream: stream)
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
