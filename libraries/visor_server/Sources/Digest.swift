import Foundation

/// What SHA-1 and SHA-256 share: the message padded to whole blocks, and
/// words read and written big-endian.
enum Digest {
    /// The message, a 1 bit, zeros to 56 bytes into a 64-byte block, and its
    /// length in bits as 8 bytes.
    static func padded(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bits = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        return message
    }

    static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    static func bytes(_ word: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8),
         UInt8(truncatingIfNeeded: word)]
    }

    static func rotateLeft(_ value: UInt32, _ by: UInt32) -> UInt32 { (value << by) | (value >> (32 - by)) }
    static func rotateRight(_ value: UInt32, _ by: UInt32) -> UInt32 { (value >> by) | (value << (32 - by)) }
}
