import Foundation
import VisorProtocol

/// Pictures' sizes read from their headers by hand — PNG, GIF, WebP, and
/// JPEG with the orientation its EXIF gives — which is what agents and
/// phones make. For systems without an image library to ask.
public struct HeaderImageMeasuring: ImageMeasuring {
    public init() {}

    public func pixelSize(path: String) -> ImageSize? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // A header is in the first bytes, but a JPEG's size comes after
        // its EXIF and colour profile, which can be large.
        guard var data = try? handle.read(upToCount: 1 << 20), data.count >= 26 else { return nil }
        if let size = Self.measure([UInt8](data)) { return size }
        guard data.first == 0xFF, let rest = try? handle.read(upToCount: 31 << 20) else { return nil }
        data.append(rest)
        return Self.measure([UInt8](data))
    }

    static func measure(_ bytes: [UInt8]) -> ImageSize? {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return png(bytes) }
        if bytes.starts(with: Array("GIF8".utf8)) { return gif(bytes) }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return webp(bytes) }
        if bytes.starts(with: [0xFF, 0xD8]) { return jpeg(bytes) }
        return nil
    }

    private static func big16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    private static func big32(_ b: [UInt8], _ at: Int) -> Int { big16(b, at) << 16 | big16(b, at + 2) }
    private static func little16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    private static func little24(_ b: [UInt8], _ at: Int) -> Int { little16(b, at) | Int(b[at + 2]) << 16 }

    private static func sized(_ width: Int, _ height: Int, turned: Bool = false) -> ImageSize? {
        guard width > 0, height > 0 else { return nil }
        return turned ? ImageSize(width: height, height: width) : ImageSize(width: width, height: height)
    }

    /// The IHDR chunk, first after the signature.
    private static func png(_ b: [UInt8]) -> ImageSize? {
        sized(big32(b, 16), big32(b, 20))
    }

    private static func gif(_ b: [UInt8]) -> ImageSize? {
        sized(little16(b, 6), little16(b, 8))
    }

    /// The first chunk says which kind: lossy, lossless, or extended.
    private static func webp(_ b: [UInt8]) -> ImageSize? {
        guard b.count >= 30 else { return nil }
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8 ": return sized(little16(b, 26) & 0x3FFF, little16(b, 28) & 0x3FFF)
        case "VP8L":
            let width = 1 + (Int(b[22] & 0x3F) << 8 | Int(b[21]))
            let height = 1 + (Int(b[24] & 0x0F) << 10 | Int(b[23]) << 2 | Int(b[22] & 0xC0) >> 6)
            return sized(width, height)
        case "VP8X": return sized(1 + little24(b, 24), 1 + little24(b, 27))
        default: return nil
        }
    }

    /// The segments up to the frame header, noting the EXIF orientation on
    /// the way: 5 to 8 are turned a quarter.
    private static func jpeg(_ b: [UInt8]) -> ImageSize? {
        var at = 2
        var orientation = 1
        while at + 9 < b.count {
            guard b[at] == 0xFF else { return nil }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { at += 2; continue }
            let length = big16(b, at + 2)
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return sized(big16(b, at + 7), big16(b, at + 5), turned: orientation >= 5)
            }
            if marker == 0xE1, let found = exifOrientation(b, from: at + 4, length: length - 2) { orientation = found }
            at += 2 + length
        }
        return nil
    }

    /// Tag 0x0112 in the first directory of an APP1 "Exif" segment.
    private static func exifOrientation(_ b: [UInt8], from start: Int, length: Int) -> Int? {
        guard length > 14, start + length <= b.count, Array(b[start..<(start + 6)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] else { return nil }
        let tiff = start + 6
        let little = b[tiff] == 0x49
        func u16(_ at: Int) -> Int { little ? little16(b, at) : big16(b, at) }
        func u32(_ at: Int) -> Int { little ? (little16(b, at) | little16(b, at + 2) << 16) : big32(b, at) }
        let directory = tiff + u32(tiff + 4)
        guard directory + 2 <= start + length else { return nil }
        for entry in 0..<u16(directory) {
            let at = directory + 2 + entry * 12
            guard at + 12 <= start + length else { return nil }
            if u16(at) == 0x0112 { return u16(at + 8) }
        }
        return nil
    }
}
