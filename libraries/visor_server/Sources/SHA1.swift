import Foundation

/// SHA-1, for the WebSocket handshake's accept key (RFC 6455 names it) and
/// nothing else.
enum SHA1 {
    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        let message = Digest.padded(data)
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 { w[i] = Digest.word(message, chunk + 4 * i) }
            for i in 16..<80 { w[i] = Digest.rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let next = Digest.rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, Digest.rotateLeft(b, 30), a, next)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap(Digest.bytes)
    }
}
