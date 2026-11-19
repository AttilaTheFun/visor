// A connection read as HTTP/1.1 frames it, for the tests' servers and
// clients: Shireworks' forward's reader, kept here once the forward stayed
// behind (Visor's copy, 19 Nov 2026).

import Foundation

/// A connection read as HTTP/1.1 frames it: heads, lengths, chunks, what
/// was read past each kept for the next.
final class WireReader {
    let socket: Int32
    private(set) var pending: Data
    private var buffer = [UInt8](repeating: 0, count: 64 << 10)

    init(_ socket: Int32, pending: Data) {
        self.socket = socket
        self.pending = pending
    }

    /// More read; false at the end (or an error, or a timeout).
    private func fill() -> Bool {
        let count = buffer.withUnsafeMutableBytes { Foundation.read(socket, $0.baseAddress, $0.count) }
        guard count > 0 else { return false }
        pending.append(contentsOf: buffer[0..<count])
        return true
    }

    /// The bytes up to the next blank line (not it), taken; nil when the
    /// connection ends first or they pass `limit`.
    func head(limit: Int) -> Data? {
        let blank = Data("\r\n\r\n".utf8)
        while true {
            if let end = pending.range(of: blank) {
                let head = Data(pending[pending.startIndex..<end.lowerBound])
                pending = Data(pending[end.upperBound...])
                return head.count <= limit ? head : nil
            }
            guard pending.count <= limit + 4, fill() else { return nil }
        }
    }

    /// A line (its CRLF taken, not given); nil past `limit` or at the end.
    func line(limit: Int) -> Data? {
        let crlf = Data("\r\n".utf8)
        while true {
            if let end = pending.range(of: crlf) {
                let line = Data(pending[pending.startIndex..<end.lowerBound])
                pending = Data(pending[end.upperBound...])
                return line.count <= limit ? line : nil
            }
            guard pending.count <= limit + 2, fill() else { return nil }
        }
    }

    /// `count` bytes to `sink`, what's pending first; false when either
    /// ends first.
    func copy(_ count: Int, to sink: Int32) -> Bool {
        var left = count
        while left > 0 {
            if pending.isEmpty, !fill() { return false }
            let taken = min(left, pending.count)
            let piece = Data(pending.prefix(taken))
            pending = Data(pending.dropFirst(taken))
            guard Self.write(piece, to: sink) else { return false }
            left -= taken
        }
        return true
    }

    /// A chunked body to `sink`, chunk by chunk as it was framed, its
    /// trailers dropped; false when it isn't chunked as it says, or either
    /// side ends first.
    func copyChunks(to sink: Int32) -> Bool {
        while true {
            guard let line = line(limit: 4096) else { return false }
            let size = String(decoding: line, as: UTF8.self).split(separator: ";", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) } ?? ""
            guard !size.isEmpty, size.count <= 15, size.allSatisfy(\.isHexDigit), let count = Int(size, radix: 16) else { return false }
            guard Self.write(Data("\(String(count, radix: 16))\r\n".utf8), to: sink) else { return false }
            if count == 0 {
                // Trailers, to the blank line: none goes on.
                while true {
                    guard let trailer = self.line(limit: 8192) else { return false }
                    if trailer.isEmpty { break }
                }
                return Self.write(Data("\r\n".utf8), to: sink)
            }
            guard copy(count, to: sink), let end = self.line(limit: 0), end.isEmpty, Self.write(Data("\r\n".utf8), to: sink) else { return false }
        }
    }

    /// `count` bytes, what's pending first; nil when the connection ends first.
    func take(_ count: Int) -> Data? {
        while pending.count < count {
            guard fill() else { return nil }
        }
        let taken = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(count))
        return taken
    }

    /// Everything to the connection's end, to `sink`.
    func drain(to sink: Int32) {
        if !pending.isEmpty, !Self.write(pending, to: sink) { return }
        pending = Data()
        while fill() {
            guard Self.write(pending, to: sink) else { return }
            pending = Data()
        }
    }

    static func write(_ data: Data, to sink: Int32) -> Bool {
        var sent = 0
        while sent < data.count {
            let wrote = data.withUnsafeBytes { Foundation.write(sink, $0.baseAddress! + sent, data.count - sent) }
            if wrote <= 0 { return false }
            sent += wrote
        }
        return true
    }
}
