// The relay as a container sees it, played here: a Unix socket whose each
// stream is one request. A CONNECT is answered 200 (or 502 for a host the
// test refuses), then what follows is echoed with "PONG " before it; a
// `POST /dns-query` is answered with the test's answer to the query.

import CRelayClientPOSIX
import Foundation
import Synchronization

final class FakeRelay: Sendable {
    let path: String
    private let listener: Int32
    /// Each request's first line, as heard.
    let heard = Mutex<[String]>([])
    private let refused: Set<String>
    private let dns: @Sendable ([UInt8]) -> [UInt8]?

    init?(refused: Set<String> = [], dns: @escaping @Sendable ([UInt8]) -> [UInt8]? = { _ in nil }) {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString.prefix(8)).sock").path
        listener = relay_client_listen_unix(path)
        guard listener >= 0 else { return nil }
        self.refused = refused
        self.dns = dns
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        while true {
            let stream = relay_client_accept(listener)
            if stream < 0 { return }
            Thread.detachNewThread { [self] in answer(stream) }
        }
    }

    private func answer(_ stream: Int32) {
        defer { close(stream) }
        var head: [UInt8] = []
        var byte: UInt8 = 0
        while !(head.count >= 4 && head.suffix(4) == [13, 10, 13, 10]) {
            guard read(stream, &byte, 1) == 1 else { return }
            head.append(byte)
        }
        let text = String(decoding: head, as: UTF8.self)
        let line = String(text.split(separator: "\r\n", maxSplits: 1).first ?? "")
        heard.withLock { $0.append(line) }
        let parts = line.split(separator: " ")
        if parts.first == "CONNECT" {
            let target = String(parts[1])
            let host = String(target.prefix { $0 != ":" })
            guard !refused.contains(host) else { return send(stream, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n") }
            send(stream, "HTTP/1.1 200 Connection Established\r\n\r\n")
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
            if count > 0 { send(stream, "PONG " + String(decoding: buffer[0..<count], as: UTF8.self)) }
            return
        }
        let length = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        var body: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while body.count < length {
            let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            body += buffer[0..<count]
        }
        guard line.hasPrefix("POST /dns-query "), let answer = dns(body) else {
            return send(stream, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        send(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: \(answer.count)\r\nConnection: close\r\n\r\n")
        _ = answer.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
    }

    private func send(_ stream: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
    }

    func stop() {
        relay_client_shutdown(listener)
        close(listener)
        unlink(path)
    }
}
