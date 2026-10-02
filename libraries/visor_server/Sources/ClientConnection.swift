// One client's WebSocket, as the server holds it.

import Foundation
import Network
import VisorProtocol

/// One client's WebSocket.
@MainActor
final class ClientConnection {
    let connection: NWConnection
    var authenticated = false
    /// Which client this is, as it named itself at login: whose window a
    /// terminal may be drawn for.
    var clientID = ""
    var onMessage: ((Envelope) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// The connection's queue is the main one: what it says is taken as
    /// it is said, in order.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            let failed = error != nil
            let closing = context?.isFinal == true
                || (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode == .close
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8), let envelope = Envelope.decode(text) {
                    self.onMessage?(envelope)
                }
                if failed || closing { self.finish(); return }
                self.receive()
            }
        }
    }

    func send(_ envelope: Envelope) {
        guard !closed else { return }
        connection.send(content: Data(envelope.encoded().utf8), contentContext: Self.text, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Says one last thing and closes once it has gone out.
    func sendLast(_ envelope: Envelope) {
        guard !closed else { return }
        let connection = self.connection
        connection.send(content: Data(envelope.encoded().utf8), contentContext: Self.text, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static var text: NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    }

    func close() {
        connection.cancel()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}
