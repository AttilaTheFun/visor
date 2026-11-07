// The Runner's GitHub proxy (docs/github-proxy.md), its first step: a
// CONNECT proxy for the servers' agents, each caller its server's token and
// its session; every host a tunnel, its bytes untouched, but never to this
// computer's own addresses.

import CVisorPOSIX
import Foundation
@testable import VisorRunner
import XCTest

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

final class GitHubProxyTests: XCTestCase {
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
        throw XCTSkip("no port for the proxy")
    }

    /// Sends `head` (and `then`, its end said) to the proxy, and reads all
    /// that comes back.
    private static func ask(_ port: Int, _ head: String, then text: String = "") throws -> String {
        let connection = visor_connect_tcp("127.0.0.1", UInt16(port))
        guard connection >= 0 else { throw XCTSkip("the proxy can't be reached") }
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

    func testACallerIsItsServersTokenAndItsSession() {
        let header = "Basic " + Data("abc123:k81jr60w2o2rfdjoxohjoc0c".utf8).base64EncodedString()
        XCTAssertEqual(GitHubProxy.caller(header), .init(token: "abc123", session: "k81jr60w2o2rfdjoxohjoc0c"))
        XCTAssertNil(GitHubProxy.caller("Bearer abc123"))
        XCTAssertNil(GitHubProxy.caller("Basic " + Data("abc123:".utf8).base64EncodedString()), "a session is named")
        XCTAssertNil(GitHubProxy.caller(nil))
        XCTAssertEqual(GitHubProxy.destination("github.com:443"), .init(host: "github.com", port: 443))
        XCTAssertEqual(GitHubProxy.destination("[2606:50c0::1]:443"), .init(host: "2606:50c0::1", port: 443))
        XCTAssertNil(GitHubProxy.destination("github.com"))
        XCTAssertNil(GitHubProxy.destination("user@github.com:443"))
    }

    /// The caller's server token admitted, the bytes go both ways untouched.
    func testATunnelPassesTheBytesThrough() throws {
        guard let upper = Upper() else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        // Loopback stands for an address off this computer here.
        let (proxy, port) = try proxy(connect: { visor_connect_tcp($0.host, $0.port) })
        defer { proxy.stop() }
        let head = "CONNECT 127.0.0.1:\(upper.port) HTTP/1.1\r\nHost: 127.0.0.1:\(upper.port)\r\n"
            + Self.authorization(Self.token, "session-a") + "\r\n"
        let answer = try Self.ask(port, head, then: "hello through the tunnel")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"), answer)
        XCTAssertTrue(answer.hasSuffix("HELLO THROUGH THE TUNNEL"), answer)
    }

    func testOnlyAServersAgentsAndOnlyConnect() throws {
        let (proxy, port) = try proxy(connect: { visor_connect_tcp($0.host, $0.port) })
        defer { proxy.stop() }
        let none = try Self.ask(port, "CONNECT github.com:443 HTTP/1.1\r\n\r\n")
        XCTAssertTrue(none.hasPrefix("HTTP/1.1 407 "), none)
        XCTAssertTrue(none.contains("Proxy-Authenticate: Basic"), none)
        let stranger = try Self.ask(port, "CONNECT github.com:443 HTTP/1.1\r\n" + Self.authorization("not-a-server", "s") + "\r\n")
        XCTAssertTrue(stranger.hasPrefix("HTTP/1.1 407 "), stranger)
        let get = try Self.ask(port, "GET http://github.com/ HTTP/1.1\r\n" + Self.authorization(Self.token, "s") + "\r\n")
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 405 "), get)
    }

    /// No name leads back to this computer: loopback is refused, whatever
    /// listens there.
    func testATunnelNeverReachesThisComputer() throws {
        guard let upper = Upper() else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        let (proxy, port) = try proxy()
        defer { proxy.stop() }
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            let answer = try Self.ask(port, "CONNECT \(host):\(upper.port) HTTP/1.1\r\n" + Self.authorization(Self.token, "s") + "\r\n")
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 403 "), "\(host): \(answer)")
        }
        XCTAssertEqual(visor_connect_tcp_public("127.0.0.1", upper.port), -1)
        XCTAssertEqual(errno, EACCES)
        XCTAssertEqual(visor_connect_tcp_public("0.0.0.0", upper.port), -1)
        XCTAssertEqual(visor_connect_tcp_public("169.254.169.254", 80), -1, "nor a cloud's metadata address")
    }
}
