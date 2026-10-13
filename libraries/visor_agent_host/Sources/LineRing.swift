import Foundation

/// The agent's latest lines, numbered, up to a size: what a server that
/// connects again is sent from where it left off. The oldest go first.
struct LineRing {
    private var lines: [(number: UInt64, text: Data)] = []
    /// Where the kept lines start in `lines`: dropped ones are cleared in
    /// batches, not one at a time.
    private var start = 0
    private var bytes = 0
    let capacity: Int
    /// The number the next line will have.
    private(set) var next: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The first line still kept (`next` when none are).
    var oldest: UInt64 { start < lines.count ? lines[start].number : next }

    /// Keeps a line; its number.
    mutating func append(_ text: Data) -> UInt64 {
        let number = next
        next += 1
        lines.append((number, text))
        bytes += text.count
        while bytes > capacity, start < lines.count - 1 {
            bytes -= lines[start].text.count
            start += 1
        }
        if start > 4096, start * 2 > lines.count {
            lines.removeFirst(start)
            start = 0
        }
        return number
    }

    /// The kept lines numbered `from` and after, in order.
    func lines(from: UInt64) -> ArraySlice<(number: UInt64, text: Data)> {
        let first = from <= oldest ? start : start + Int(min(from - oldest, UInt64(lines.count - start)))
        return lines[first...]
    }
}
