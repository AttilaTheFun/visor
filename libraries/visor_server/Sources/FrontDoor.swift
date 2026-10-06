// One port for everything: a connection's first bytes say whether it is
// a WebSocket (the live channel, `Upgrade: websocket`) or a request of the
// REST side, and it goes to the one or the other with what has arrived.
// So a front of any kind — a proxy, a tunnel, nothing at all — forwards
// one address, and the client finds the socket at its root and the API
// under /api. The door reads the connection throughout (a connection is
// read once); what it hands on is a stream of its own that forwards.

import Foundation

@MainActor
final class FrontDoor {
    private let stream: any ByteStream
    private var received = Data()
    /// The side that took the connection, once one has.
    private var taken: DoorStream?
    private let socket: (any ByteStream, Data) -> Void
    private let http: (any ByteStream, Data) -> Void

    /// How much of a head is read before a connection that sends no
    /// complete one is dropped.
    static let largestHead = 64 * 1024

    init(stream: any ByteStream, socket: @escaping (any ByteStream, Data) -> Void, http: @escaping (any ByteStream, Data) -> Void) {
        self.stream = stream
        self.socket = socket
        self.http = http
    }

    /// The door lives as long as the connection reads: the connection's
    /// reader holds it (nothing else does).
    func start() {
        stream.receive { chunk in
            if let taken = self.taken { return taken.forward(chunk) }
            guard let chunk else { return self.stream.close() }
            self.received.append(chunk)
            guard let end = HTTPServer.headerEnd(self.received) else {
                if self.received.count > Self.largestHead { self.stream.close() }
                return
            }
            let head = String(decoding: self.received[..<end], as: UTF8.self)
            let upgrade = HTTPServer.headers(head)["upgrade"]?.lowercased() == "websocket"
            let door = DoorStream(stream: self.stream)
            self.taken = door
            (upgrade ? self.socket : self.http)(door, self.received)
            self.received = Data()
        }
    }
}

/// The connection as the side that took it sees it: what the door reads
/// is forwarded to whoever asked to receive; sending and closing go
/// straight through.
@MainActor
private final class DoorStream: ByteStream {
    private let stream: any ByteStream
    private var receiver: (@MainActor (Data?) -> Void)?
    /// What arrived before anyone asked to receive, and the end if it came.
    private var pending: [Data?] = []

    init(stream: any ByteStream) { self.stream = stream }

    func forward(_ chunk: Data?) {
        if let receiver { receiver(chunk) } else { pending.append(chunk) }
    }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {
        receiver = chunk
        let held = pending
        pending = []
        for item in held { chunk(item) }
    }

    func send(_ data: Data, sent: (@MainActor () -> Void)?) { stream.send(data, sent: sent) }

    func close() { stream.close() }
}
