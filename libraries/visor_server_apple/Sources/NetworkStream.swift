import Foundation
import Network
import VisorServer

/// One Network framework connection's bytes, on the main queue.
@MainActor
final class NetworkStream: ByteStream {
    private let connection: NWConnection
    /// The end has been told: it is told once, whichever way it came.
    private var ended = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.end(chunk)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        read(into: chunk)
    }

    private func read(into chunk: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            let over = complete || error != nil
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { chunk(data) }
                if over {
                    self.end(chunk)
                    self.connection.cancel()
                } else {
                    self.read(into: chunk)
                }
            }
        }
    }

    private func end(_ chunk: @MainActor (Data?) -> Void) {
        guard !ended else { return }
        ended = true
        chunk(nil)
    }

    func send(_ data: Data, sent: (@MainActor () -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { _ in
            MainActor.assumeIsolated { sent?() }
        })
    }

    func close() {
        ended = true
        connection.cancel()
    }
}
