// A QR code, made here: byte mode, error correction level L (M where it
// fits as well), the smallest version that holds the text, the mask with
// the least penalty. Plain Swift, so the same code draws on every
// platform (the Mac's CoreImage is not everywhere). The symbol is a
// square grid of modules; `QRCodeShape` draws it.

struct QRCode: Equatable {
    /// Modules per side.
    let size: Int
    /// Row-major; true is dark.
    let modules: [Bool]

    func isDark(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// The code for `text` (UTF-8), or nil when it does not fit a version
    /// 40 symbol.
    init?(_ text: String, level: Level = .low) {
        let bytes = Array(text.utf8)
        guard let version = (1...40).first(where: { Self.dataCapacity(version: $0, level: level) >= Self.dataLength(bytes.count, version: $0) }) else { return nil }
        let codewords = Self.codewords(bytes, version: version, level: level)
        var canvas = Canvas(version: version)
        canvas.drawFunctionPatterns()
        canvas.drawCodewords(codewords)
        // Each mask tried on the data alone; the best kept.
        var best = 0, lowest = Int.max
        for mask in 0..<8 {
            canvas.applyMask(mask)
            canvas.drawFormatBits(level: level, mask: mask)
            let penalty = canvas.penalty()
            if penalty < lowest { lowest = penalty; best = mask }
            canvas.applyMask(mask)
        }
        canvas.applyMask(best)
        canvas.drawFormatBits(level: level, mask: best)
        size = canvas.size
        modules = canvas.modules
    }

    enum Level: Int {
        case low = 1, medium = 0
        var eccPerBlock: [Int] {
            switch self {
            case .low: [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
            case .medium: [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
            }
        }
        var blocks: [Int] {
            switch self {
            case .low: [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25]
            case .medium: [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
            }
        }
    }

    // MARK: Capacity

    /// Bits a byte-mode segment of `count` bytes takes in `version`.
    static func dataLength(_ count: Int, version: Int) -> Int { 4 + (version < 10 ? 8 : 16) + count * 8 }

    static func rawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let aligns = version / 7 + 2
            result -= (25 * aligns - 10) * aligns - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    /// Bits of data (not error correction) a version holds at a level.
    static func dataCapacity(version: Int, level: Level) -> Int {
        (rawDataModules(version: version) / 8 - level.eccPerBlock[version] * level.blocks[version]) * 8
    }

    // MARK: Codewords

    /// The data bits, padded, split into blocks with their error
    /// correction, and interleaved as the symbol lays them out.
    static func codewords(_ bytes: [UInt8], version: Int, level: Level) -> [UInt8] {
        var bits = Bits()
        bits.append(4, count: 4)
        bits.append(bytes.count, count: version < 10 ? 8 : 16)
        for byte in bytes { bits.append(Int(byte), count: 8) }
        let capacity = dataCapacity(version: version, level: level)
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad: UInt8 = 0xEC
        while bits.count < capacity {
            bits.append(Int(pad), count: 8)
            pad ^= 0xEC ^ 0x11
        }
        let data = bits.bytes

        let blocks = level.blocks[version], ecc = level.eccPerBlock[version]
        let raw = rawDataModules(version: version) / 8
        let shortBlocks = blocks - raw % blocks
        let shortLength = raw / blocks
        var split: [[UInt8]] = []
        var offset = 0
        for index in 0..<blocks {
            let length = shortLength - ecc + (index < shortBlocks ? 0 : 1)
            var block = Array(data[offset..<(offset + length)])
            offset += length
            let correction = ReedSolomon.remainder(block, degree: ecc)
            // Short blocks take a slot of padding so every block is as
            // long as the longest; the slot is skipped on the way out.
            if index < shortBlocks { block.append(0) }
            block += correction
            split.append(block)
        }
        var out: [UInt8] = []
        for index in 0..<split[0].count {
            for (position, block) in split.enumerated() where index != shortLength - ecc || position >= shortBlocks {
                out.append(block[index])
            }
        }
        return out
    }

    /// A growing string of bits.
    struct Bits {
        private(set) var count = 0
        private var storage: [UInt8] = []
        mutating func append(_ value: Int, count length: Int) {
            for shift in stride(from: length - 1, through: 0, by: -1) {
                if count % 8 == 0 { storage.append(0) }
                if (value >> shift) & 1 == 1 { storage[count / 8] |= UInt8(0x80 >> (count % 8)) }
                count += 1
            }
        }
        var bytes: [UInt8] { storage }
    }

    /// Reed–Solomon over GF(2^8) with the QR polynomial.
    enum ReedSolomon {
        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            for shift in stride(from: 7, through: 0, by: -1) {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= Int((y >> shift) & 1) * Int(x)
            }
            return UInt8(z & 0xFF)
        }

        static func divisor(degree: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: degree)
            result[degree - 1] = 1
            var root: UInt8 = 1
            for _ in 0..<degree {
                for index in 0..<degree {
                    result[index] = multiply(result[index], root)
                    if index + 1 < degree { result[index] ^= result[index + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func remainder(_ data: [UInt8], degree: Int) -> [UInt8] {
            let divisor = divisor(degree: degree)
            var result = [UInt8](repeating: 0, count: degree)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for index in 0..<degree { result[index] ^= multiply(divisor[index], factor) }
            }
            return result
        }
    }

    // MARK: The symbol

    struct Canvas {
        let version: Int
        let size: Int
        var modules: [Bool]
        /// Where function patterns are: not data, not masked.
        var reserved: [Bool]

        init(version: Int) {
            self.version = version
            size = version * 4 + 17
            modules = [Bool](repeating: false, count: size * size)
            reserved = modules
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y * size + x] = dark
            reserved[y * size + x] = true
        }

        func dark(_ x: Int, _ y: Int) -> Bool { modules[y * size + x] }

        mutating func drawFunctionPatterns() {
            for index in 0..<size {
                set(6, index, index % 2 == 0)
                set(index, 6, index % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            let positions = alignmentPositions()
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    let corner = (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0)
                    if !corner { drawAlignment(x, y) }
                }
            }
            drawFormatBits(level: .low, mask: 0)
            drawVersion()
        }

        private mutating func drawFinder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let distance = max(abs(dx), abs(dy))
                    set(x, y, distance != 2 && distance != 4)
                }
            }
        }

        private mutating func drawAlignment(_ cx: Int, _ cy: Int) {
            for dy in -2...2 {
                for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
            }
        }

        func alignmentPositions() -> [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
            var result = [6]
            var position = size - 7
            for _ in 0..<(count - 1) {
                result.insert(position, at: 1)
                position -= step
            }
            return result
        }

        mutating func drawFormatBits(level: Level, mask: Int) {
            let data = level.rawValue << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0...5 { set(8, index, bit(index)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for index in 9..<15 { set(14 - index, 8, bit(index)) }
            for index in 0..<8 { set(size - 1 - index, 8, bit(index)) }
            for index in 8..<15 { set(8, size - 15 + index, bit(index)) }
            set(8, size - 8, true)
        }

        private mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for index in 0..<18 {
                let dark = (bits >> index) & 1 == 1
                let a = size - 11 + index % 3, b = index / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        /// The codewords, zigzagged up and down in two-column strips from
        /// the right, the timing column skipped.
        mutating func drawCodewords(_ data: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for column in 0..<2 {
                        let x = right - column
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        guard !reserved[y * size + x], index < data.count * 8 else { continue }
                        modules[y * size + x] = (data[index >> 3] >> (7 - (index & 7))) & 1 == 1
                        index += 1
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !reserved[y * size + x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y * size + x].toggle() }
                }
            }
        }

        /// The standard's penalty: runs, blocks, finder-like patterns, balance.
        func penalty() -> Int {
            var result = 0
            for y in 0..<size {
                var run = 0
                var last: Bool?
                var history = [Int](repeating: 0, count: 7)
                for x in 0..<size {
                    let color = dark(x, y)
                    if color == last { run += 1; if run == 5 { result += 3 } else if run > 5 { result += 1 } }
                    else { history = finderHistory(history, run); if last == false { result += finderPenalty(history) * 40 }; last = color; run = 1 }
                }
                history = finderHistory(history, run)
                result += finderPenalty(history) * 40
            }
            for x in 0..<size {
                var run = 0
                var last: Bool?
                var history = [Int](repeating: 0, count: 7)
                for y in 0..<size {
                    let color = dark(x, y)
                    if color == last { run += 1; if run == 5 { result += 3 } else if run > 5 { result += 1 } }
                    else { history = finderHistory(history, run); if last == false { result += finderPenalty(history) * 40 }; last = color; run = 1 }
                }
                history = finderHistory(history, run)
                result += finderPenalty(history) * 40
            }
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let color = dark(x, y)
                    if color == dark(x + 1, y), color == dark(x, y + 1), color == dark(x + 1, y + 1) { result += 3 }
                }
            }
            let darkCount = modules.filter { $0 }.count
            let total = size * size
            let k = (abs(darkCount * 20 - total * 10) + total - 1) / total - 1
            result += k * 10
            return result
        }

        private func finderHistory(_ history: [Int], _ run: Int) -> [Int] { Array(history.dropFirst()) + [run] }

        /// Whether the last runs look like a finder pattern (1:1:3:1:1
        /// with light either side).
        private func finderPenalty(_ h: [Int]) -> Int {
            let n = h[3]
            guard n > 0, n % 3 == 0 else { return 0 }
            let core = h[2] == n / 3 && h[4] == n / 3 && h[1] == n / 3 && h[5] == n / 3
            guard core else { return 0 }
            return (h[0] >= n / 3 * 4 ? 1 : 0) + (h[6] >= n / 3 * 4 ? 1 : 0)
        }
    }
}
