// The egress proxy (MultiPass's GitHubProxy, its egress): a CONNECT's
// target and an absolute URL read; a tunnel's bytes passed through
// untouched; plain HTTP forwarded as origin-form; never to this computer's
// own addresses; and GitHub's hosts a tunnel like any other until phase 2's
// interceptor, which opens them when there is one. Each reached through the
// relay, the agent proxy's only way in. Moved from MultiPass's tests
// (Logan, 2026-11-14).

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy
import XCTest

final class EgressProxyTests: XCTestCase {
    private static let relayToken = "relay-secret"

    /// A relay listener before an egress proxy (`connect`: the tests'
    /// servers on loopback; none: off this computer only).
    private func relay(interceptor: (any GitHubIntercepting)? = nil,
                       connect: (@Sendable (EgressProxy.Destination) -> Int32)? = nil) throws -> (RelayListener, Int, Lines) {
        let lines = Lines()
        let proxy = connect.map { EgressProxy(connect: $0, interceptor: interceptor, log: { lines.add($0) }) }
            ?? EgressProxy(interceptor: interceptor, log: { lines.add($0) })
        for _ in 0..<20 {
            let port = Int.random(in: 20000...45000)
            guard let relay = RelayListener(port: port, relayToken: { Self.relayToken }, proxy: proxy, log: { lines.add($0) }) else { continue }
            relay.start()
            return (relay, port, lines)
        }
        throw XCTSkip("no port for the relay")
    }

    /// Sends the relay's header, `head` and `text`, says it's done, and
    /// reads all that comes back.
    private static func ask(_ port: Int, _ head: String, then text: String = "") throws -> String {
        let connection = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard connection >= 0 else { throw XCTSkip("the relay can't be reached") }
        defer { close(connection) }
        let bytes = ProxyProtocolHeader.relayed(lease: "lease-7", relayToken: relayToken).encoded() + Array((head + text).utf8)
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        agent_proxy_shutdown_write(connection)
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: answer, as: UTF8.self)
    }

    func testTargetsAreRead() {
        XCTAssertEqual(EgressProxy.destination("github.com:443"), .init(host: "github.com", port: 443))
        XCTAssertEqual(EgressProxy.destination("[2606:50c0::1]:443"), .init(host: "2606:50c0::1", port: 443))
        XCTAssertNil(EgressProxy.destination("github.com"))
        XCTAssertNil(EgressProxy.destination("user@github.com:443"))
        XCTAssertEqual(EgressProxy.absolute("http://example.com")?.path, "/")
        XCTAssertEqual(EgressProxy.absolute("http://example.com:8080/x")?.destination.port, 8080)
        XCTAssertNil(EgressProxy.absolute("https://example.com/"), "https is CONNECT's")
        XCTAssertNil(EgressProxy.absolute("http://user@example.com/"))
    }

    func testTheAgentIsItsAgentIDAlone() {
        let agent = "0B5E7A52-1C1B-4E2A-9C3D-5F6A7B8C9D0E"
        XCTAssertEqual(EgressProxy.agent(in: HTTPRequest(method: "CONNECT", path: "a:1", headers: [("x-agent-id", "\(agent)@visor")])),
                       agent.lowercased())
        XCTAssertNil(EgressProxy.agent(in: HTTPRequest(method: "CONNECT", path: "a:1", headers: [("X-Agent-ID", "someone")])))
        XCTAssertNil(EgressProxy.agent(in: HTTPRequest(method: "CONNECT", path: "a:1", headers: [("Authorization", agent)])))
    }

    /// The bytes go both ways untouched.
    func testATunnelPassesTheBytesThrough() throws {
        guard let upper = Upper() else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        // Loopback stands for an address off this computer here.
        let (relay, port, lines) = try relay(connect: { agent_proxy_connect_tcp($0.host, $0.port) })
        defer { relay.stop() }
        let head = "CONNECT 127.0.0.1:\(upper.port) HTTP/1.1\r\nHost: 127.0.0.1:\(upper.port)\r\n\r\n"
        let answer = try Self.ask(port, head, then: "hello through the tunnel")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"), answer)
        XCTAssertTrue(answer.hasSuffix("HELLO THROUGH THE TUNNEL"), answer)
        XCTAssertTrue(lines.all.contains("container:lease-7 CONNECT 127.0.0.1:\(upper.port) tunnel"), "\(lines.all)")
    }

    /// An absolute http:// request is forwarded as an origin-form one, the
    /// proxy's own headers left out, and not half-closed: the server answers
    /// once it has the request's headers, as a real one does.
    func testPlainHTTPIsForwarded() throws {
        guard let upper = Upper(answersAtHeadersEnd: true) else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        let (relay, port, _) = try relay(connect: { agent_proxy_connect_tcp($0.host, $0.port) })
        defer { relay.stop() }
        let answer = try Self.ask(port, "GET http://127.0.0.1:\(upper.port)/path?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Proxy-Authorization: Basic eDp5\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("GET /PATH?Q=1 HTTP/1.1\r\n"), answer)
        XCTAssertFalse(answer.contains("PROXY-AUTHORIZATION"), answer)
        XCTAssertTrue(answer.contains("CONNECTION: CLOSE"), answer)
    }

    /// No name leads back to this computer: loopback is refused, whatever
    /// listens there.
    func testATunnelNeverReachesThisComputer() throws {
        guard let upper = Upper() else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        let (relay, port, _) = try relay()
        defer { relay.stop() }
        for host in ["127.0.0.1", "[::1]"] {
            let answer = try Self.ask(port, "CONNECT \(host):\(upper.port) HTTP/1.1\r\n\r\n")
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 403 "), "\(host): \(answer)")
        }
        let plain = try Self.ask(port, "GET http://127.0.0.1:\(upper.port)/ HTTP/1.1\r\n\r\n")
        XCTAssertTrue(plain.hasPrefix("HTTP/1.1 403 "), plain)
        // A name: refused when it resolves here, unreachable where it doesn't
        // (a container with no localhost in its hosts); never a tunnel.
        let named = try Self.ask(port, "CONNECT localhost:\(upper.port) HTTP/1.1\r\n\r\n")
        XCTAssertFalse(named.hasPrefix("HTTP/1.1 200 "), named)
        XCTAssertEqual(agent_proxy_connect_tcp_public("127.0.0.1", upper.port), -1)
        XCTAssertEqual(errno, EACCES)
        XCTAssertEqual(agent_proxy_connect_tcp_public("0.0.0.0", upper.port), -1)
        XCTAssertEqual(agent_proxy_connect_tcp_public("169.254.169.254", 80), -1, "nor a cloud's metadata address")
    }

    /// Phase 2's seam: with an interceptor, a CONNECT it takes is its own
    /// once answered; one it doesn't is a tunnel as before.
    func testAnInterceptorOpensWhatItTakesAndTheRestIsATunnel() throws {
        guard let upper = Upper() else { throw XCTSkip("no port for the server") }
        defer { upper.stop() }
        let interceptor = FakeInterceptor()
        let (relay, port, lines) = try relay(interceptor: interceptor, connect: { _ in agent_proxy_connect_tcp("127.0.0.1", upper.port) })
        defer { relay.stop() }
        let opened = try Self.ask(port, "CONNECT GitHub.com:443 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(opened, "HTTP/1.1 200 Connection Established\r\n\r\nintercepted")
        XCTAssertEqual(interceptor.adopted.withLock { $0 }, ["github.com container:lease-7"])
        XCTAssertTrue(lines.all.contains("container:lease-7 CONNECT GitHub.com:443 opened"), "\(lines.all)")
        let tunnelled = try Self.ask(port, "CONNECT github.com:22 HTTP/1.1\r\n\r\n", then: "ssh")
        XCTAssertTrue(tunnelled.hasSuffix("SSH"), "not the interceptor's: \(tunnelled)")
    }

    /// A private address egressAllow lets through that the system says has
    /// no route (or no permission) is, on macOS, Shireworks without its Local
    /// Network permission: the log says so plainly. Any other failure, and a
    /// connection that reached its place, says nothing of it.
    func testALANDestinationUnreachableSaysLocalNetworkPermission() {
        XCTAssertEqual(EgressProxy.unreachable(privateFailure: false), "unreachable")
        XCTAssertTrue(EgressProxy.unreachable(privateFailure: true).hasPrefix("unreachable: Local Network permission: grant Shireworks it once"))
        // A connection that was made, or failed to a public address, leaves the flag clear.
        guard let upper = Upper() else { return }
        defer { upper.stop() }
        let reached = agent_proxy_connect_tcp("127.0.0.1", upper.port)
        XCTAssertGreaterThanOrEqual(reached, 0)
        close(reached)
        XCTAssertEqual(agent_proxy_last_failure_private(), 0)
        XCTAssertEqual(EgressProxy.unreachable(), "unreachable")
    }
}

/// Phase 2's interceptor, played: GitHub's hosts on 443 are its own, each
/// answered with "intercepted".
private final class FakeInterceptor: GitHubIntercepting {
    let adopted = Locked<[String]>([])

    func intercepts(_ destination: EgressProxy.Destination) -> Bool {
        destination.port == 443 && GitHubHosts.contains(destination.host)
    }

    func adopt(_ client: Int32, host: String, caller: EgressProxy.Caller) {
        adopted.withLock { $0.append("\(host) \(caller.session)") }
        HTTPRequest.send(client, Data("intercepted".utf8))
        close(client)
    }
}
