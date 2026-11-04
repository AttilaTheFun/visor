/// A WebSocket's frames as a client writes and reads them (RFC 6455): what
/// it sends is masked, what the server sends is not (and is taken masked or
/// not). Pure functions over bytes, so they are tested apart from sockets.
enum MCPWebSocketFrames {
    enum Opcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    /// One frame read from the start of the bytes.
    struct Frame: Equatable {
        let final: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// Larger than anything Visor's server says to an agent's tools; a frame
    /// that says it is larger ends the connection.
    static let largest = 64 * 1024 * 1024

    /// A whole frame, masked with `mask` (four bytes).
    static func frame(_ opcode: UInt8, _ payload: [UInt8], mask: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode]
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            out += [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        out += mask
        for (index, byte) in payload.enumerated() { out.append(byte ^ mask[index % 4]) }
        return out
    }

    /// Four bytes to mask a frame with.
    static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }

    /// What reading the start of `buffer` came to.
    enum Read: Equatable {
        /// A frame, and how many bytes it took.
        case frame(Frame, Int)
        /// Not all of the next frame has come yet.
        case incomplete
        /// A frame no client takes: too large.
        case invalid
    }

    static func read(_ buffer: [UInt8]) -> Read {
        guard buffer.count >= 2 else { return .incomplete }
        let final = buffer[0] & 0x80 != 0
        let opcode = buffer[0] & 0x0F
        let masked = buffer[1] & 0x80 != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return .incomplete }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return .incomplete }
            var long: UInt64 = 0
            for index in 2..<10 { long = long << 8 | UInt64(buffer[index]) }
            guard long <= UInt64(largest) else { return .invalid }
            length = Int(long)
            offset = 10
        }
        guard length <= largest else { return .invalid }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return .incomplete }
            mask = Array(buffer[offset..<offset + 4])
            offset += 4
        }
        guard buffer.count >= offset + length else { return .incomplete }
        var payload = Array(buffer[offset..<offset + length])
        if masked { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        return .frame(Frame(final: final, opcode: opcode, payload: payload), offset + length)
    }
}
