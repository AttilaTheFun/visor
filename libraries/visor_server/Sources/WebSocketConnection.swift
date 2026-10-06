// A WebSocket over a connection's bytes (RFC 6455): the opening handshake,
// then frames — text messages in and out, pings answered, a close
// returned. Read and written here, so the server speaks it the same way on
// every system; the system carries only the bytes.

import Foundation

@MainActor
final class WebSocketConnection {
    private let stream: any ByteStream
    /// What has arrived and not yet been taken as a header or a frame.
    private var buffer: [UInt8] = []
    private var opened = false
    /// A message arriving in pieces: what has come, and what kind it is.
    private var pieces: [UInt8] = []
    private var piecesOpcode: UInt8?
    private(set) var closed = false

    /// Each text message, whole.
    var onText: ((String) -> Void)?
    /// Once, when the connection is over, whichever end ended it.
    var onClose: (() -> Void)?

    /// Larger than any message the protocol has (a picture goes over the
    /// REST side): one that says it is larger ends the connection.
    static let largest = 64 * 1024 * 1024
    /// The handshake's request is a few hundred bytes.
    static let largestHeader = 64 * 1024
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private enum Opcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    /// - Parameter received: what arrived before the connection was known
    ///   to be a WebSocket's (its upgrade request, or the start of it).
    init(stream: any ByteStream, received: Data = Data()) {
        self.stream = stream
        buffer = Array(received)
    }

    func start() {
        if !buffer.isEmpty { take(Data()) }
        stream.receive { [weak self] chunk in self?.take(chunk) }
    }

    func send(text: String) {
        guard opened, !closed else { return }
        stream.send(Self.frame(Opcode.text, Array(text.utf8)), sent: nil)
    }

    /// Says one last thing and closes once it has gone out.
    func sendLast(text: String) {
        guard opened, !closed else { return }
        stream.send(Self.frame(Opcode.text, Array(text.utf8))) { [weak self] in self?.close() }
    }

    /// Closes it: a close frame, then the connection.
    func close() {
        guard !closed else { return }
        if opened { stream.send(Self.frame(Opcode.close, [0x03, 0xE8]), sent: nil) }
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        stream.close()
        onClose?()
    }

    private func take(_ chunk: Data?) {
        guard !closed else { return }
        guard let chunk else { return finish() }
        buffer.append(contentsOf: chunk)
        if !opened { handshake() }
        while opened, !closed, let frame = nextFrame() { handle(frame) }
    }

    /// The upgrade request, once it is whole: answered with the accept key,
    /// or, when it is not a WebSocket's, refused.
    private func handshake() {
        guard let end = HTTPServer.headerEnd(buffer) else {
            if buffer.count > Self.largestHeader { finish() }
            return
        }
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeFirst(end + 4)
        let headers = HTTPServer.headers(head)
        guard let key = headers["sec-websocket-key"], headers["upgrade"]?.lowercased() == "websocket" else {
            stream.send(Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) { [weak self] in
                self?.finish()
            }
            return
        }
        let accept = Data(SHA1.hash(Data((key + Self.guid).utf8))).base64EncodedString()
        let answer = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        stream.send(Data(answer.utf8), sent: nil)
        opened = true
    }

    private struct Frame {
        let final: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// The first whole frame in the buffer, taken out of it; nil until one
    /// is whole.
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
            guard long <= UInt64(Self.largest) else {
                finish()
                return nil
            }
            length = Int(long)
            offset = 10
        }
        guard length <= Self.largest else {
            finish()
            return nil
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
                deliver(frame.opcode, frame.payload)
            } else {
                piecesOpcode = frame.opcode
                pieces = frame.payload
            }
        case Opcode.continuation:
            guard let opcode = piecesOpcode else { return finish() }
            pieces.append(contentsOf: frame.payload)
            guard pieces.count <= Self.largest else { return finish() }
            if frame.final {
                let message = pieces
                pieces = []
                piecesOpcode = nil
                deliver(opcode, message)
            }
        case Opcode.ping:
            stream.send(Self.frame(Opcode.pong, frame.payload), sent: nil)
        case Opcode.pong:
            break
        case Opcode.close:
            // Answered with the code it gave (the first two bytes), then over.
            let stream = self.stream
            stream.send(Self.frame(Opcode.close, Array(frame.payload.prefix(2)))) { stream.close() }
            closed = true
            onClose?()
        default:
            finish()
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        // The protocol's messages are text (JSON); a binary one is read as
        // text too.
        onText?(String(decoding: payload, as: UTF8.self))
    }

    /// A frame as the server sends it: whole, unmasked.
    static func frame(_ opcode: UInt8, _ payload: [UInt8]) -> Data {
        var head: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            head.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            head += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            head.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { head.append(UInt8(truncatingIfNeeded: payload.count >> shift)) }
        }
        return Data(head + payload)
    }
}
