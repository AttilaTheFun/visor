// A request as the relay listener reads it off a container's stream, and
// the plain answers it gives: MultiPass's MCPProxy.Request, read, reply and
// send, moved here alone (the MCP proxy itself is phase 2's: MCPAnswering).

import CAgentProxyPOSIX
import Foundation

/// A request as it came: its line, its headers (as given), its body.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(name: String, value: String)]
    /// The body, or as much of it as came with the head when it is longer
    /// than the reader would hold.
    public var body: Data
    /// What the body's length says is still to come on the stream, unread.
    public var unreadBody: Int
    /// The head as it came, without its blank line (empty for one made
    /// here): the forward reads it again, strictly (Forward.Request.parse).
    public var head: Data = Data()

    public init(method: String, path: String, headers: [(name: String, value: String)] = [], body: Data = Data(), unreadBody: Int = 0) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.unreadBody = unreadBody
    }

    /// The body's length, as its `Content-Length` says (0 without one).
    public var contentLength: Int { header("Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max($0, 0) } ?? 0 }

    /// A header's value, its name in any case.
    public func header(_ name: String) -> String? { headers.first { $0.name.lowercased() == name.lowercased() }?.value }

    /// The request on `connection`, up to its body's length when that is at
    /// most `bodyLimit` (else what came with the head, the rest left unread:
    /// `unreadBody`); nil for one that isn't HTTP. A head is at most 1 MB.
    /// `bodyWithin`: the seconds its body may take in all, on top of each
    /// read's own timeout (`perRead`, put back after), so a body trickled in
    /// a byte at a time ends then, short (NCH's review of #451).
    public static func read(_ connection: Int32, bodyLimit: Int = 64 << 10, bodyWithin: TimeInterval? = nil,
                            perRead: Int32 = 0) -> HTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        let blank = Data("\r\n\r\n".utf8)
        while data.range(of: blank) == nil {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(connection, $0.baseAddress, $0.count) }
            if count <= 0 || data.count > 1 << 20 { return nil }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let end = data.range(of: blank) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        var request = HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(data[end.upperBound...]))
        request.head = Data(data[..<end.lowerBound])
        let length = request.contentLength
        request.unreadBody = max(length - request.body.count, 0)
        guard length <= bodyLimit else { return request }
        request.readRest(from: connection, within: bodyWithin, perRead: perRead)
        return request
    }

    /// What `unreadBody` says is still to come, read from `connection` now:
    /// all of it, or what came before the connection ended, a read's
    /// timeout passed, or `within` seconds in all did (each read's timeout
    /// then cut to what's left, and `perRead` put back after).
    public mutating func readRest(from connection: Int32, within: TimeInterval? = nil, perRead: Int32 = 0) {
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        let deadline = within.map { Date().addingTimeInterval($0) }
        defer { if deadline != nil, perRead > 0 { agent_proxy_set_receive_timeout(connection, perRead) } }
        while unreadBody > 0 {
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { break }
                let cap = perRead > 0 ? Double(perRead) : left
                agent_proxy_set_receive_timeout(connection, Int32(max(1, min(cap, left).rounded(.up))))
            }
            let count = buffer.withUnsafeMutableBytes { Foundation.read(connection, $0.baseAddress, min($0.count, unreadBody)) }
            if count <= 0 { break }
            body.append(contentsOf: buffer[0..<count])
            unreadBody -= count
        }
    }

    /// `count` bytes from one to the other as they come; false when either
    /// ends first.
    public static func copy(_ count: Int, from source: Int32, to sink: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var left = count
        while left > 0 {
            let got = buffer.withUnsafeMutableBytes { Foundation.read(source, $0.baseAddress, min($0.count, left)) }
            if got <= 0 { return false }
            var sent = 0
            while sent < got {
                let wrote = buffer.withUnsafeBytes { Foundation.write(sink, $0.baseAddress! + sent, got - sent) }
                if wrote <= 0 { return false }
                sent += wrote
            }
            left -= got
        }
        return true
    }

    /// A plain-text answer, and the connection's end said.
    public static func reply(_ connection: Int32, _ status: String, _ text: String) {
        let body = Data(text.utf8)
        send(connection, Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
    }

    /// All of `data` written, or as much as the other side took.
    public static func send(_ connection: Int32, _ data: Data) {
        var sent = 0
        while sent < data.count {
            let wrote = data.withUnsafeBytes { Foundation.write(connection, $0.baseAddress! + sent, data.count - sent) }
            if wrote <= 0 { return }
            sent += wrote
        }
    }
}
