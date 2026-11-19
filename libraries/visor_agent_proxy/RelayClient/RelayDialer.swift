// The way out of a container with no network: the relay's Unix socket
// (/run/agent-proxy/relay.sock), each stream carried by Shireworks to
// agent-proxy's relay listener, which knows the container by the relay's
// header. A stream is one request: a CONNECT, then the bytes both ways; or
// a DNS query over HTTPS, answered and closed.

import CRelayClientPOSIX
import Foundation

/// Opens streams through the relay.
public struct RelayDialer: Sendable {
    public let path: String

    public init(path: String = RelayDialer.defaultPath) {
        self.path = path
    }

    /// The relay's socket: agent-proxy's path, else MultiPass's where only that is there (a server from before 0.15).
    public static var defaultPath: String {
        let current = "/run/agent-proxy/relay.sock", earlier = "/run/multipass/relay.sock"
        return FileManager.default.fileExists(atPath: current) || !FileManager.default.fileExists(atPath: earlier) ? current : earlier
    }

    /// A stream to `host:port` through agent-proxy, once it has answered 200;
    /// nil if the relay or agent-proxy didn't (`problem` says what).
    public func open(host: String, port: UInt16, problem: (String) -> Void = { _ in }) -> Int32? {
        let stream = relay_client_connect_unix(path)
        guard stream >= 0 else {
            problem("the relay (\(path)) doesn't answer")
            return nil
        }
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        Self.send(stream, Array("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8))
        guard let head = Self.readHead(stream), let status = Self.status(head) else {
            problem("CONNECT \(target): no answer")
            close(stream)
            return nil
        }
        guard status == 200 else {
            problem("CONNECT \(target): \(head.split(separator: "\r\n").first ?? "")")
            close(stream)
            return nil
        }
        return stream
    }

    /// The answer to a DNS query (its bytes), asked of agent-proxy's resolver
    /// over HTTPS's wire form (RFC 8484); nil without one.
    public func query(_ bytes: [UInt8]) -> [UInt8]? {
        let stream = relay_client_connect_unix(path)
        guard stream >= 0 else { return nil }
        defer { close(stream) }
        Self.send(stream, Array(("POST /dns-query HTTP/1.1\r\nHost: agent-proxy\r\nContent-Type: application/dns-message\r\n"
            + "Accept: application/dns-message\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n").utf8) + bytes)
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
        }
        let blank: [UInt8] = [13, 10, 13, 10]
        guard heard.count >= 4, let end = (0...(heard.count - 4)).first(where: { Array(heard[$0..<($0 + 4)]) == blank }),
              Self.status(String(decoding: heard[..<end], as: UTF8.self)) == 200 else { return nil }
        let body = Array(heard[(end + 4)...])
        return body.isEmpty ? nil : body
    }

    /// The answer's head, read a byte at a time so nothing after it is
    /// taken from the stream.
    static func readHead(_ stream: Int32) -> String? {
        var head: [UInt8] = []
        var byte: UInt8 = 0
        while head.count < 16 << 10 {
            guard read(stream, &byte, 1) == 1 else { return nil }
            head.append(byte)
            if head.count >= 4, head.suffix(4) == [13, 10, 13, 10] { return String(decoding: head, as: UTF8.self) }
        }
        return nil
    }

    /// An HTTP answer head's status code.
    static func status(_ head: String) -> Int? {
        let line = (head.split(separator: "\r\n", maxSplits: 1).first ?? "").split(separator: " ")
        guard line.count >= 2, line[0].hasPrefix("HTTP/1.") else { return nil }
        return Int(line[1])
    }

    static func send(_ stream: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { write(stream, $0.baseAddress! + sent, bytes.count - sent) }
            if wrote <= 0 { return }
            sent += wrote
        }
    }
}
