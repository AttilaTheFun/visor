// One WebSocket to a server's socket file (RFC 6455, as a client): the
// opening handshake, then frames, masked as a client's are. Its events are
// queued for the socket service's `next`, as the host's own service queues
// them: "open", "message <text>", "close <reason>", "error <reason>".

import Foundation
import VisorSystem

@MainActor
final class SocketFileWebSocket {
    private let connect: SocketFileConnect
    private var stream: (any ByteStream)?
    /// What has arrived and not yet been taken as the handshake's answer
    /// or a frame.
    private var buffer: [UInt8] = []
    private var opened = false
    /// A message arriving in pieces.
    private var pieces: [UInt8] = []
    private var piecesOpcode: UInt8?
    /// Its events not yet taken, and who waits for the next.
    private var events: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    /// No more events after those queued.
    private(set) var finished = false

    private enum Opcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    init(connect: @escaping SocketFileConnect) {
        self.connect = connect
    }

    /// Connects to `socket` and asks for the channel at `path`, with
    /// `headers` on the opening request.
    func start(socket: String, path: String, headers: [String: String]) {
        let connect = connect
        Task { [weak self] in
            let stream = await connect(socket)
            guard let self else { return stream?.close() ?? () }
            guard let stream else {
                push("error no server answers at \(socket)")
                return finish()
            }
            guard !finished else { return stream.close() }
            self.stream = stream
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            var head = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            stream.receive { [weak self] chunk in self?.take(chunk) }
            stream.send(Data((head + "\r\n").utf8), sent: nil)
        }
    }

    func send(_ text: String) {
        guard opened, !finished, let stream else { return }
        stream.send(Self.frame(Opcode.text, Array(text.utf8)), sent: nil)
    }

    /// Closed from this end: a close frame, then the connection.
    func close() {
        guard !finished else { return }
        if opened, let stream {
            stream.send(Self.frame(Opcode.close, [0x03, 0xE8])) { stream.close() }
        } else {
            stream?.close()
        }
        push("close closed")
        finish()
    }

    /// The next event, waited for; throws once there are no more.
    func next() async throws -> String {
        if !events.isEmpty { return events.removeFirst() }
        if finished { throw SocketFileSocketGone() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    /// Whether every event has been taken and none will come.
    var drained: Bool { finished && events.isEmpty }

    private func push(_ event: String) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(throwing: SocketFileSocketGone())
    }

    private func take(_ chunk: Data?) {
        guard !finished else { return }
        guard let chunk else {
            push(opened ? "close connection closed" : "error the server closed the connection")
            return finish()
        }
        buffer.append(contentsOf: chunk)
        if !opened { handshake() }
        while opened, !finished, let frame = nextFrame() { handle(frame) }
    }

    /// The handshake's answer, once whole: 101, and the channel is open.
    private func handshake() {
        let bytes = buffer
        guard bytes.count >= 4, let end = (0...(bytes.count - 4)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10
            && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }) else { return }
        let statusLine = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        buffer.removeFirst(end + 4)
        guard statusLine.split(separator: " ").dropFirst().first == "101" else {
            push("error \(statusLine)")
            stream?.close()
            return finish()
        }
        opened = true
        push("open")
    }

    private struct Frame {
        let final: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// The first whole frame in the buffer (a server's: unmasked), taken out
    /// of it; nil until one is whole.
    private func nextFrame() -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let final = buffer[0] & 0x80 != 0
        let opcode = buffer[0] & 0x0F
        let masked = buffer[1] & 0x80 != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            var long: UInt64 = 0
            for byte in buffer[2..<10] { long = long << 8 | UInt64(byte) }
            guard long <= UInt64(Int32.max) else {
                push("close a frame too large")
                stream?.close()
                finish()
                return nil
            }
            length = Int(long)
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        var payload = Array(buffer[offset..<(offset + length)])
        if masked {
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        buffer.removeFirst(offset + length)
        return Frame(final: final, opcode: opcode, payload: payload)
    }

    private func handle(_ frame: Frame) {
        switch frame.opcode {
        case Opcode.text, Opcode.binary:
            if frame.final {
                push("message " + String(decoding: frame.payload, as: UTF8.self))
            } else {
                piecesOpcode = frame.opcode
                pieces = frame.payload
            }
        case Opcode.continuation:
            guard piecesOpcode != nil else { return }
            pieces.append(contentsOf: frame.payload)
            if frame.final {
                let message = pieces
                pieces = []
                piecesOpcode = nil
                push("message " + String(decoding: message, as: UTF8.self))
            }
        case Opcode.ping:
            stream?.send(Self.frame(Opcode.pong, frame.payload), sent: nil)
        case Opcode.pong:
            break
        case Opcode.close:
            let code = frame.payload.count >= 2 ? Int(frame.payload[0]) << 8 | Int(frame.payload[1]) : 1000
            if let stream {
                stream.send(Self.frame(Opcode.close, Array(frame.payload.prefix(2)))) { stream.close() }
            }
            push("close \(code)")
            finish()
        default:
            break
        }
    }

    /// A frame as a client sends it: whole, masked.
    static func frame(_ opcode: UInt8, _ payload: [UInt8]) -> Data {
        var head: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            head.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            head.append(0x80 | 126)
            head.append(UInt8(payload.count >> 8))
            head.append(UInt8(payload.count & 0xFF))
        } else {
            head.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { head.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        head.append(contentsOf: mask)
        var masked = payload
        for index in masked.indices { masked[index] ^= mask[index % 4] }
        return Data(head + masked)
    }
}
