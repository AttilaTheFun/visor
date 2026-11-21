// Servers on loopback the agent proxy's tests talk to, and its log lines
// kept for a test to read. Moved from MultiPass's tests (Logan, 2026-11-14).

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy

/// Log lines, kept for a test to read.
final class Lines: Sendable {
    private let lines = Locked<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// A socket listening on 127.0.0.1 at a port the system picked (port 0,
/// read back), and that port: not one picked at random, which another
/// test, in this process or a target run beside it, could pick too. Nil
/// when it can't listen.
func loopbackListener() -> (socket: Int32, port: UInt16)? {
    let listener = agent_proxy_listen(0, 0)
    guard listener >= 0 else { return nil }
    guard let port = boundPort(listener) else {
        close(listener)
        return nil
    }
    return (listener, port)
}

/// A port on 127.0.0.1 where a connection is refused until `release`: a
/// socket bound there without SO_REUSEADDR and never listened on, so no
/// other listener can take it while it's held (as one just let go can be).
/// At the file's level, where `bind` is the system's (in a test case,
/// NSObject's own `bind` comes first on the Mac).
func closedLoopbackPort() -> (port: UInt16, release: @Sendable () -> Void)? {
    #if canImport(Glibc)
    let holder = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let holder = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard holder >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, let port = boundPort(holder) else {
        close(holder)
        return nil
    }
    return (port, { close(holder) })
}

/// The port `socket` is bound to.
private func boundPort(_ socket: Int32) -> UInt16? {
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    return named == 0 ? UInt16(bigEndian: bound.sin_port) : nil
}

/// A listener on a loopback port the system picked, its connections each
/// handled on a thread of its own by `handle`.
final class LoopbackServer: Sendable {
    let port: UInt16
    private let listener: Int32

    init?(_ handle: @escaping @Sendable (Int32) -> Void) {
        guard let (socket, port) = loopbackListener() else { return nil }
        self.port = port
        listener = socket
        Thread.detachNewThread { [listener] in
            while true {
                let connection = agent_proxy_accept(listener)
                if connection < 0 { return }
                Thread.detachNewThread { handle(connection) }
            }
        }
    }

    func stop() {
        agent_proxy_shutdown(listener)
        close(listener)
    }
}

/// Answers each connection with "PONG" once it has read something.
final class Pong: Sendable {
    let server: LoopbackServer
    var port: UInt16 { server.port }

    func stop() { server.stop() }

    init?() {
        guard let server = LoopbackServer({ connection in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            let answer = Array("PONG".utf8)
            _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }) else { return nil }
        self.server = server
    }
}

/// Answers each connection with what it read, upper-cased, once the client
/// has said all it will (or, `answersAtHeadersEnd`, once it has read a
/// request's headers).
final class Upper: Sendable {
    let server: LoopbackServer
    var port: UInt16 { server.port }

    func stop() { server.stop() }

    init?(answersAtHeadersEnd: Bool = false) {
        guard let server = LoopbackServer({ connection in
            var heard = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                heard.append(contentsOf: buffer[0..<count])
                if answersAtHeadersEnd, heard.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            let answer = Array(String(decoding: heard, as: UTF8.self).uppercased().utf8)
            _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }) else { return nil }
        self.server = server
    }
}

/// Sends back every byte it reads, as it reads it, and keeps them all.
final class Echo: Sendable {
    let server: LoopbackServer
    var port: UInt16 { server.port }

    func stop() { server.stop() }

    let heard: Locked<[UInt8]>

    init?() {
        let heard = Locked<[UInt8]>([])
        self.heard = heard
        guard let server = LoopbackServer({ connection in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                heard.withLock { $0 += buffer[0..<count] }
                _ = buffer.withUnsafeBytes { write(connection, $0.baseAddress, count) }
            }
            close(connection)
        }) else { return nil }
        self.server = server
    }
}

/// An HTTP server that keeps each request it hears and answers each with
/// `answer` as JSON (or as `contentType` says).
final class FakeEndpoint: Sendable {
    let server: LoopbackServer
    var port: UInt16 { server.port }

    func stop() { server.stop() }

    let requests: Locked<[String]>

    init?(answer: String = #"{"jsonrpc":"2.0","id":1,"result":{}}"#, contentType: String = "application/json") {
        let requests = Locked<[String]>([])
        self.requests = requests
        guard let server = LoopbackServer({ connection in
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil || !request.suffix(2).elementsEqual(Data("}\n".utf8)) && request.count < 4096 {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                request.append(contentsOf: buffer[0..<count])
                if let end = request.range(of: Data("\r\n\r\n".utf8)), request.count > end.upperBound { break }
            }
            requests.withLock { $0.append(String(decoding: request, as: UTF8.self)) }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(answer.utf8.count)\r\nConnection: close\r\n\r\n" + answer
            _ = Array(response.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }) else { return nil }
        self.server = server
    }
}

/// Reads a request's head and as many bytes of body as its Content-Length
/// says, then answers how many it got.
final class Counter: Sendable {
    let server: LoopbackServer
    var port: UInt16 { server.port }

    func stop() { server.stop() }

    init?() {
        guard let server = LoopbackServer({ connection in
            var data = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let blank = Array("\r\n\r\n".utf8)
            var end: Int?
            var length = 0
            while true {
                if end == nil, data.count >= 4, let found = (0...(data.count - 4)).first(where: { Array(data[$0..<($0 + 4)]) == blank }) {
                    end = found + 4
                    let head = String(decoding: data[..<found], as: UTF8.self).lowercased()
                    length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                }
                if let end, data.count - end >= length { break }
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                data += buffer[0..<count]
            }
            let got = max(data.count - (end ?? data.count), 0)
            let body = "got \(got)"
            let answer = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
            _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }) else { return nil }
        self.server = server
    }
}

/// A container's connection to the relay listener, read an answer at a time.
final class TestClient {
    let socket: Int32
    private let reader: WireReader

    init?(port: Int) {
        socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { return nil }
        agent_proxy_set_receive_timeout(socket, 10)
        reader = WireReader(socket, pending: Data())
    }

    func send(_ bytes: [UInt8]) { _ = WireReader.write(Data(bytes), to: socket) }

    /// The next answer's head, without its blank line.
    func head() -> String? { reader.head(limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) } }

    /// The next answer: its head, and its body as its length says (none without one).
    func response() -> (head: String, body: String)? {
        guard let head = head() else { return nil }
        let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard let body = reader.take(length) else { return nil }
        return (head, String(decoding: body, as: UTF8.self))
    }

    func take(_ count: Int) -> [UInt8]? { reader.take(count).map(Array.init) }

    func close() { Foundation.close(socket) }
}
