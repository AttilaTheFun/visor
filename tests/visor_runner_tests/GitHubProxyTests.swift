// The Runner's GitHub proxy (docs/github-proxy.md), its first step: a
// CONNECT proxy for the servers' agents, each caller its server's token and
// its session; every host a tunnel, its bytes untouched, but never to this
// computer's own addresses.

import CVisorPOSIX
import Foundation
@testable import VisorRunner
import Testing

/// A server on loopback that answers each connection with what it read,
/// upper-cased, once the client has said all it will.
private final class Upper: Sendable {
    let port: UInt16
    private let listener: Int32

    init?() {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...45000)
            let socket = visor_listen(port, 0)
            if socket >= 0 {
                self.port = port
                listener = socket
                Thread.detachNewThread { [self] in serve() }
                return
            }
        }
        return nil
    }

    private func serve() {
        while true {
            let connection = visor_accept(listener)
            if connection < 0 { return }
            Thread.detachNewThread {
                var heard = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    heard.append(contentsOf: buffer[0..<count])
                }
                let answer = Array(String(decoding: heard, as: UTF8.self).uppercased().utf8)
                _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                close(connection)
            }
        }
    }

    func stop() {
        visor_shutdown(listener)
        close(listener)
    }
}

@Suite final class GitHubProxyTests {
    private static let token = "server-token"

    private func proxy(connect: (@Sendable (GitHubProxy.Destination) -> Int32)? = nil) throws -> (GitHubProxy, Int) {
        for _ in 0..<20 {
            let port = Int.random(in: 20000...45000)
            let admits: @Sendable (String) -> Bool = { $0 == Self.token }
            let made = connect.map { GitHubProxy(port: port, admits: admits, connect: $0, log: { _ in }) }
                ?? GitHubProxy(port: port, admits: admits, log: { _ in })
            if let made {
                made.start()
                return (made, port)
            }
        }
        try Test.cancel("no port for the proxy")
    }

    /// Sends `head` (and `then`, its end said) to the proxy, and reads all
    /// that comes back.
    private static func ask(_ port: Int, _ head: String, then text: String = "") throws -> String {
        let connection = visor_connect_tcp("127.0.0.1", UInt16(port))
        guard connection >= 0 else { try Test.cancel("the proxy can't be reached") }
        defer { close(connection) }
        let bytes = Array((head + text).utf8)
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        visor_shutdown_write(connection)
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: answer, as: UTF8.self)
    }

    private static func authorization(_ token: String, _ session: String) -> String {
        "Proxy-Authorization: Basic " + Data("\(token):\(session)".utf8).base64EncodedString() + "\r\n"
    }

    @Test func testACallerIsItsServersTokenAndItsSession() {
        let header = "Basic " + Data("abc123:k81jr60w2o2rfdjoxohjoc0c".utf8).base64EncodedString()
        #expect(GitHubProxy.caller(header) == .init(token: "abc123", session: "k81jr60w2o2rfdjoxohjoc0c"))
        #expect(GitHubProxy.caller("Bearer abc123") == nil)
        #expect((GitHubProxy.caller("Basic " + Data("abc123:".utf8).base64EncodedString())) == nil, "a session is named")
        #expect(GitHubProxy.caller(nil) == nil)
        #expect(GitHubProxy.destination("github.com:443") == .init(host: "github.com", port: 443))
        #expect(GitHubProxy.destination("[2606:50c0::1]:443") == .init(host: "2606:50c0::1", port: 443))
        #expect(GitHubProxy.destination("github.com") == nil)
        #expect(GitHubProxy.destination("user@github.com:443") == nil)
    }

    /// The caller's server token admitted, the bytes go both ways untouched.
    @Test func testATunnelPassesTheBytesThrough() throws {
        guard let upper = Upper() else { try Test.cancel("no port for the server") }
        defer { upper.stop() }
        // Loopback stands for an address off this computer here.
        let (proxy, port) = try proxy(connect: { visor_connect_tcp($0.host, $0.port) })
        defer { proxy.stop() }
        let head = "CONNECT 127.0.0.1:\(upper.port) HTTP/1.1\r\nHost: 127.0.0.1:\(upper.port)\r\n"
            + Self.authorization(Self.token, "session-a") + "\r\n"
        let answer = try Self.ask(port, head, then: "hello through the tunnel")
        #expect(answer.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"), Comment(rawValue: answer))
        #expect(answer.hasSuffix("HELLO THROUGH THE TUNNEL"), Comment(rawValue: answer))
    }

    @Test func testOnlyAServersAgentsAndOnlyConnect() throws {
        let (proxy, port) = try proxy(connect: { visor_connect_tcp($0.host, $0.port) })
        defer { proxy.stop() }
        let none = try Self.ask(port, "CONNECT github.com:443 HTTP/1.1\r\n\r\n")
        #expect(none.hasPrefix("HTTP/1.1 407 "), Comment(rawValue: none))
        #expect(none.contains("Proxy-Authenticate: Basic"), Comment(rawValue: none))
        let stranger = try Self.ask(port, "CONNECT github.com:443 HTTP/1.1\r\n" + Self.authorization("not-a-server", "s") + "\r\n")
        #expect(stranger.hasPrefix("HTTP/1.1 407 "), Comment(rawValue: stranger))
        let get = try Self.ask(port, "GET http://github.com/ HTTP/1.1\r\n" + Self.authorization(Self.token, "s") + "\r\n")
        #expect(get.hasPrefix("HTTP/1.1 405 "), Comment(rawValue: get))
    }

    /// No name leads back to this computer: loopback is refused, whatever
    /// listens there.
    @Test func testATunnelNeverReachesThisComputer() throws {
        guard let upper = Upper() else { try Test.cancel("no port for the server") }
        defer { upper.stop() }
        let (proxy, port) = try proxy()
        defer { proxy.stop() }
        for host in ["127.0.0.1", "[::1]"] {
            let answer = try Self.ask(port, "CONNECT \(host):\(upper.port) HTTP/1.1\r\n" + Self.authorization(Self.token, "s") + "\r\n")
            #expect(answer.hasPrefix("HTTP/1.1 403 "), "\(host): \(answer)")
        }
        // A name: refused when it resolves here, unreachable where it doesn't
        // (a container with no localhost in its hosts); never a tunnel.
        let named = try Self.ask(port, "CONNECT localhost:\(upper.port) HTTP/1.1\r\n" + Self.authorization(Self.token, "s") + "\r\n")
        #expect(!named.hasPrefix("HTTP/1.1 200 "), Comment(rawValue: named))
        #expect(visor_connect_tcp_public("127.0.0.1", upper.port) == -1)
        #expect(errno == EACCES)
        #expect(visor_connect_tcp_public("0.0.0.0", upper.port) == -1)
        #expect(visor_connect_tcp_public("169.254.169.254", 80) == -1, "nor a cloud's metadata address")
    }
}
