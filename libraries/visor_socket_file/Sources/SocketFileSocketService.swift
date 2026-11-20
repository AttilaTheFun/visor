// The live channel of a server at its socket file (SocketFileURL,
// `ws+unix://…/`): a WebSocket per connection, by id, its events handed out
// one at a time, as the host's own socket service does for a URL.

import Foundation
import VisorProtocol
import VisorServices
import VisorSystem

@MainActor
public final class SocketFileSocketService: VisorSocketService {
    private let connect: SocketFileConnect
    /// Headers every opening request carries besides its own.
    private let extraHeaders: @Sendable () -> [String: String]
    private var sockets: [Int32: SocketFileWebSocket] = [:]
    private var nextID: Int32 = 1

    public init(connect: @escaping SocketFileConnect, headers: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.connect = connect
        extraHeaders = headers
    }

    /// The opening request carries them.
    public var sendsHeaders: Bool { true }

    public func open(url: String) -> Int32 { open(url: url, headers: [:]) }

    public func open(url: String, headers: [String: String]) -> Int32 {
        guard let (socket, path) = SocketFileURL.split(url) else { return -1 }
        let id = nextID
        nextID += 1
        let connection = SocketFileWebSocket(connect: connect)
        sockets[id] = connection
        connection.start(socket: socket, path: path, headers: headers.merging(extraHeaders(), uniquingKeysWith: { mine, _ in mine }))
        return id
    }

    public func send(id: Int32, text: String) {
        sockets[id]?.send(text)
    }

    public func disconnect(id: Int32) {
        sockets[id]?.close()
    }

    public func next(id: Int32) async throws -> String {
        guard let socket = sockets[id] else { throw SocketFileSocketGone() }
        do {
            let event = try await socket.next()
            if socket.drained { sockets[id] = nil }
            return event
        } catch {
            sockets[id] = nil
            throw error
        }
    }

    public func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
