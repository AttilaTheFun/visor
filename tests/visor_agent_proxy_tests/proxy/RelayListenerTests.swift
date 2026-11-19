// The relay listener (Visor's docs/server-proxy.md, "Containers: no
// network"): a container's stream, named by the relay's header with the
// relay's token, has its CONNECT tunnelled as that container's, and logged;
// a stream with another token, the relay's own LOCAL, or no header at all
// is closed unanswered. The dial-ins are joined byte for byte, under the
// agent proxy's names and MultiPass's; DNS is answered over HTTPS; `GET /`
// answers the health probe; `/mcp/<name>` is what it is given's to answer.
// Moved from MultiPass's tests (Logan, 2026-11-14), then into Visor from
// Shireworks' v0.15.1 without its forward's and its MCP's.

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy
import XCTest

final class RelayListenerTests: XCTestCase {
    private static let relayToken = "relay-secret"
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A relay listener before an egress proxy whose tunnels may reach
    /// loopback (the tests' servers) unless `connect` says otherwise, its
    /// egress log, and the lines it logged.
    private func relay(dns: DNSForwarder? = nil, mcp: (any MCPAnswering)? = nil, dialIns: [DialIn] = [],
                       maxConnections: Int = RelayListener.defaultMaxConnections,
                       maxConnectionsPerLease: Int = RelayListener.defaultMaxConnectionsPerLease,
                       maxUnnamed: Int = RelayListener.defaultMaxUnnamed,
                       headTimeout: Int = RelayListener.defaultHeadTimeout,
                       headerTimeout: Double = RelayListener.defaultHeaderTimeout,
                       bodyWithin: TimeInterval = RelayListener.defaultBodyWithin,
                       connect: @escaping @Sendable (EgressProxy.Destination) -> Int32 = { agent_proxy_connect_tcp($0.host, $0.port) })
        throws -> (RelayListener, Int, EgressLog, Lines) {
        let lines = Lines()
        let egress = EgressLog(file: folder.appendingPathComponent("egress.log"))
        let proxy = EgressProxy(connect: connect, egress: egress, log: { lines.add($0) })
        for _ in 0..<20 {
            let port = Int.random(in: 20000...45000)
            guard let relay = RelayListener(port: port, relayToken: { Self.relayToken }, proxy: proxy, dns: dns, mcp: mcp,
                                            dialIns: { dialIns },
                                            maxConnections: maxConnections, maxConnectionsPerLease: maxConnectionsPerLease,
                                            maxUnnamed: maxUnnamed, headTimeout: headTimeout, headerTimeout: headerTimeout,
                                            bodyWithin: bodyWithin, log: { lines.add($0) }) else { continue }
            relay.start()
            return (relay, port, egress, lines)
        }
        throw XCTSkip("no ports")
    }

    private static var header: [UInt8] { ProxyProtocolHeader.relayed(lease: "lease-42", relayToken: relayToken).encoded() }

    /// Sends `bytes` to the relay's port and reads what comes back, to the
    /// stream's end, sending `more` once an answer's head has come (and then
    /// saying it's done, with `ending`).
    private func send(_ bytes: [UInt8], to port: Int, then more: [UInt8] = [], ending: Bool = false) -> String {
        String(decoding: sendBytes(bytes, to: port, then: more, ending: ending), as: UTF8.self)
    }

    private func sendBytes(_ bytes: [UInt8], to port: Int, then more: [UInt8] = [], ending: Bool = false) -> [UInt8] {
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { return [] }
        defer { close(socket) }
        _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sentMore = more.isEmpty
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
            if !sentMore, String(decoding: heard, as: UTF8.self).contains("\r\n\r\n") {
                _ = more.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
                if ending { agent_proxy_shutdown_write(socket) }
                sentMore = true
            }
        }
        return heard
    }

    func testAContainersConnectIsTunnelledAsThatContainersAndLogged() throws {
        guard let pong = Pong() else { throw XCTSkip("no port for the server") }
        defer { pong.stop() }
        let (relay, port, egress, lines) = try relay()
        defer { relay.stop() }
        let agent = "0B5E7A52-1C1B-4E2A-9C3D-5F6A7B8C9D0E"
        let connect = "CONNECT 127.0.0.1:\(pong.port) HTTP/1.1\r\nX-Agent-ID: \(agent)@visor\r\n\r\n"
        let answer = send(Self.header + Array(connect.utf8), to: port, then: Array("PING\n".utf8))
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 "), answer)
        XCTAssertTrue(answer.hasSuffix("PONG"), answer)
        XCTAssertEqual(egress.entries().map { "\($0.lease) \($0.agentClaimed ?? "-") \($0.host):\($0.port) \($0.route) \($0.outcome)" },
                       ["lease-42 \(agent.lowercased()) 127.0.0.1:\(pong.port) egress tunnelled"], "in the egress log as the container's")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("container:lease-42 CONNECT 127.0.0.1:\(pong.port)") }, "\(lines.all)")
    }

    /// Logan (2026-11-14): egress stays open, and each connection is a line
    /// of its own: host, port, lease, agent, time and route, as JSON, and
    /// never the request's contents, headers or tokens.
    func testEachConnectionIsALineWithItsRouteAndNothingOfTheRequest() throws {
        guard let pong = Pong(), let upper = Upper(answersAtHeadersEnd: true) else { throw XCTSkip("no port for the servers") }
        defer { pong.stop(); upper.stop() }
        let dialIn = DialIn(name: "visor", port: 7434, hostPort: Int(pong.port))
        let (relay, port, egress, _) = try relay(dialIns: [dialIn], connect: { destination in
            // GitHub's hosts, here, are the test's server: plain egress until phase 2.
            GitHubHosts.contains(destination.host) ? agent_proxy_connect_tcp("127.0.0.1", pong.port)
                : agent_proxy_connect_tcp(destination.host, destination.port)
        })
        defer { relay.stop() }
        let secret = "Proxy-Authorization: Basic c2VjcmV0LXRva2VuOnM=\r\nAuthorization: Bearer ghp_secret\r\n"
        _ = send(Self.header + Array("CONNECT github.com:443 HTTP/1.1\r\n\(secret)\r\n".utf8), to: port, then: Array("PING\n".utf8))
        _ = send(Self.header + Array("CONNECT visor.agent.internal:7434 HTTP/1.1\r\n\r\n".utf8), to: port, then: Array("PING\n".utf8))
        _ = send(Self.header + Array("GET http://127.0.0.1:\(upper.port)/private?token=abc HTTP/1.1\r\n\(secret)\r\n".utf8), to: port)
        let entries = egress.entries()
        XCTAssertEqual(entries.map { "\($0.host):\($0.port) \($0.route.rawValue) \($0.outcome)" },
                       ["github.com:443 github tunnelled", "visor.agent.internal:7434 dial-in tunnelled", "127.0.0.1:\(upper.port) egress forwarded"])
        XCTAssertTrue(entries.allSatisfy { $0.lease == "lease-42" && $0.agentClaimed == nil && abs($0.time.timeIntervalSinceNow) < 60 })
        let text = try String(contentsOf: egress.file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, text)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["time", "host", "port", "lease", "route", "outcome"], "the agent claimed only when named")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: first["time"] as? String ?? ""), "an ISO 8601 time")
        for word in ["secret", "ghp_", "c2VjcmV0", "private", "token", "PING"] {
            XCTAssertFalse(text.contains(word), "no request contents, headers or tokens: \(word) in \(text)")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: egress.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// The `visor` dial-in (Visor's container wrappers' only way to it,
    /// plaintext gRPC): spliced byte for byte, both ways, under the agent
    /// proxy's name and MultiPass's, where the egress proxy would refuse
    /// loopback.
    func testTheVisorDialInIsAPureSpliceUnderEitherName() throws {
        guard let echo = Echo() else { throw XCTSkip("no port for the server") }
        defer { echo.stop() }
        let dialIn = DialIn(name: "visor", port: 7434, hostPort: Int(echo.port))
        let (relay, port, _, lines) = try relay(dialIns: [dialIn], connect: { _ in
            errno = EACCES
            return -1
        })
        defer { relay.stop() }
        // HTTP/2's preface and frames, with gRPC metadata and every byte
        // value: nothing of it is read, changed or held back. Some comes with
        // the CONNECT itself, the rest after its answer.
        let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        let frames: [UInt8] = [0, 0, 6, 4, 0, 0, 0, 0, 0] + [0, 3, 0, 0, 0, 100]
            + Array("authorization: Bearer agent-token\r\ngrpc-timeout: 5S\r\nx-visor-session: 42\r\n".utf8) + Array(0...255)
        for name in ["visor.agent.internal", "Visor.Agent.Internal"] {
            let before = echo.heard.withLock { $0.count }
            let connect = Array("CONNECT \(name):7434 HTTP/1.1\r\nHost: \(name):7434\r\n\r\n".utf8)
            let heard = sendBytes(Self.header + connect + preface, to: port, then: frames, ending: true)
            let established = Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            XCTAssertEqual(Array(heard.prefix(established.count)), established, name)
            XCTAssertEqual(Array(heard.dropFirst(established.count)), preface + frames, "\(name): back exactly as sent")
            XCTAssertEqual(Array(echo.heard.withLock { $0 }.dropFirst(before)), preface + frames, "\(name): the server got exactly what was sent")
            XCTAssertTrue(lines.all.contains("relay: container:lease-42 CONNECT \(name):7434 dial-in to loopback port \(echo.port)"), "\(lines.all)")
        }
    }

    func testADialInReachesOnlyItsOwnNameAndPort() throws {
        guard let pong = Pong() else { throw XCTSkip("no port for the server") }
        defer { pong.stop() }
        let dialIn = DialIn(name: "visor", port: 7434, hostPort: Int(pong.port))
        let (relay, port, _, _) = try relay(dialIns: [dialIn], connect: { _ in
            errno = EACCES
            return -1
        })
        defer { relay.stop() }
        let otherPort = send(Self.header + Array("CONNECT visor.agent.internal:7433 HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(otherPort.hasPrefix("HTTP/1.1 403 "), "only the dial-in's port: \(otherPort)")
        let otherName = send(Self.header + Array("CONNECT shireworks.agent.internal:7434 HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(otherName.hasPrefix("HTTP/1.1 403 "), "only the dial-in's name: \(otherName)")
        let loopback = send(Self.header + Array("CONNECT 127.0.0.1:\(pong.port) HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(loopback.hasPrefix("HTTP/1.1 403 "), "loopback itself still goes by the egress proxy: \(loopback)")
    }

    func testADialInsNameIsOneDNSLabel() {
        XCTAssertTrue(DialIn.isName("visor"))
        XCTAssertTrue(DialIn.isName("visor-2"))
        XCTAssertFalse(DialIn.isName("Visor"))
        XCTAssertFalse(DialIn.isName("visor.local"))
        XCTAssertFalse(DialIn.isName("-visor"))
        XCTAssertFalse(DialIn.isName(""))
        XCTAssertEqual(DialIn(name: "visor", port: 7434, hostPort: 7434).host, "visor.agent.internal")
        XCTAssertTrue(DialIn.isOwn("visor.agent.internal"))
        XCTAssertTrue(DialIn.isOwn("AGENT.INTERNAL"))
        XCTAssertFalse(DialIn.isOwn("visor.multipass.internal"), "MultiPass's, retired")
        XCTAssertFalse(DialIn.isOwn("evilagent.internal"))
        XCTAssertFalse(DialIn.isOwn("evilmultipass.internal"))
    }

    func testAStreamWithoutTheRelaysTokenOrHeaderIsClosedUnanswered() throws {
        let (relay, port, egress, lines) = try relay()
        defer { relay.stop() }
        let connect = Array("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
        let stranger = ProxyProtocolHeader.relayed(lease: "lease-42", relayToken: "not-the-relay").encoded()
        XCTAssertEqual(send(stranger + connect, to: port), "")
        XCTAssertEqual(send(ProxyProtocolHeader(command: .local).encoded() + connect, to: port), "", "the relay's own LOCAL")
        XCTAssertEqual(send(connect, to: port), "", "no header")
        XCTAssertTrue(lines.all.contains("relay: a stream without the relay's token: closed"), "\(lines.all)")
        XCTAssertEqual(egress.entries(), [], "nothing went anywhere")
    }

    /// The primary container's health probe (`curl … --unix-socket
    /// /run/agent-proxy/relay.sock http://agent-proxy/`) is answered, not closed.
    func testTheHealthProbesGetIsAnswered() throws {
        let (relay, port, _, _) = try relay()
        defer { relay.stop() }
        let probe = "GET / HTTP/1.1\r\nHost: agent-proxy\r\nUser-Agent: curl/8.5.0\r\nAccept: */*\r\n\r\n"
        let answer = send(Self.header + Array(probe.utf8), to: port)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 "), answer)
        XCTAssertTrue(answer.hasSuffix("agent-proxy"), answer)
    }

    func testWhatTheRelayDoesntTakeIsRefused() throws {
        let (relay, port, _, _) = try relay()
        defer { relay.stop() }
        let answer = send(Self.header + Array("GET /nothing HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 405 "), answer)
        let noResolver = send(Self.header + Array("POST /dns-query HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8), to: port)
        XCTAssertTrue(noResolver.hasPrefix("HTTP/1.1 404 "), noResolver)
    }

    /// The MCP seam: with no MCP proxy, `/mcp/` is not found; with one,
    /// the call is its to answer, with the caller.
    func testAContainersMCPCallIsNotFoundWithoutAnMCPProxyAndElseItsToAnswer() throws {
        do {
            let (relay, port, _, _) = try relay()
            defer { relay.stop() }
            let answer = send(Self.header + Array("POST /mcp/gh HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8), to: port)
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 404 "), answer)
        }
        let mcp = FakeMCP()
        let (relay, port, _, lines) = try relay(mcp: mcp)
        defer { relay.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let answer = send(Self.header + Array("POST /mcp/gh?x=1 HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8), to: port)
        XCTAssertEqual(answer, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        XCTAssertEqual(mcp.heard.withLock { $0 }, ["lease-42 POST /mcp/gh?x=1 \(body)"])
        XCTAssertTrue(lines.all.contains("relay: container:lease-42 POST /mcp/gh"), "\(lines.all)")
    }

    /// Shireworks' own routes stay behind (Visor's copy, 19 Nov 2026): the
    /// `shireworks.agent.internal` forward is no dial-in, so a CONNECT to it
    /// is refused, and a plain request to it too, never looked up.
    func testShireworksForwardIsGone() throws {
        let (relay, port, egress, _) = try relay()
        defer { relay.stop() }
        let connect = send(Self.header + Array("CONNECT shireworks.agent.internal:80 HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(connect.hasPrefix("HTTP/1.1 403 "), connect)
        let plain = send(Self.header + Array("GET http://shireworks.agent.internal/v1/machines HTTP/1.1\r\n\r\n".utf8), to: port)
        XCTAssertTrue(plain.hasPrefix("HTTP/1.1 403 "), plain)
        XCTAssertEqual(egress.entries().map { "\($0.host) \($0.route.rawValue) \($0.outcome)" },
                       ["shireworks.agent.internal dial-in refused", "shireworks.agent.internal dial-in refused"])
    }

    /// An MCP call that trickles in is ended at its body's time in all,
    /// never reaching what answers `/mcp/<name>`.
    func testATrickledMCPCallIsRefusedAtItsBodysTimeInAll() throws {
        let mcp = FakeMCP()
        let (relay, port, _, _) = try relay(mcp: mcp, headTimeout: 5, bodyWithin: 2)
        defer { relay.stop() }
        let client = try XCTUnwrap(TestClient(port: port))
        defer { client.close() }
        client.send(Self.header + Array("POST /mcp/gh HTTP/1.1\r\nContent-Length: 100\r\n\r\n{".utf8))
        let started = Date()
        let stop = Locked(false)
        let socket = client.socket
        let trickle = Thread {
            while !stop.withLock({ $0 }), Date().timeIntervalSince(started) < 8 {
                Thread.sleep(forTimeInterval: 0.5)
                if !stop.withLock({ $0 }) { _ = WireReader.write(Data(" ".utf8), to: socket) }
            }
        }
        trickle.start()
        let answer = client.head()
        stop.withLock { $0 = true }
        // The trickle's last write done before its client closes.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "ended by its 2 s in all")
        XCTAssertTrue(answer?.hasPrefix("HTTP/1.1 413 ") == true, answer ?? "no answer")
        XCTAssertTrue(mcp.heard.withLock { $0.isEmpty }, "a trickled call never reaches the MCP server")
    }

    /// A stream opened and left open (CONNECT answered), as a connection
    /// held by a container: its socket, or -1.
    private func hold(_ port: Int, lease: String, to target: String) -> (socket: Int32, answer: String) {
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { return (-1, "") }
        let bytes = ProxyProtocolHeader.relayed(lease: lease, relayToken: Self.relayToken).encoded()
            + Array("CONNECT \(target) HTTP/1.1\r\n\r\n".utf8)
        _ = bytes.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        agent_proxy_set_receive_timeout(socket, 5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
        return (socket, String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self))
    }

    /// NCH's review of #414: at most so many streams at once in all (more
    /// closed unanswered) and of one lease (more answered 503), counted
    /// until each ends.
    func testStreamsAreCappedInAllAndByLease() throws {
        guard let echo = Echo() else { throw XCTSkip("no port for the server") }
        defer { echo.stop() }
        let (relay, port, _, lines) = try relay(maxConnections: 2, maxConnectionsPerLease: 1)
        defer { relay.stop() }
        let target = "127.0.0.1:\(echo.port)"
        let first = hold(port, lease: "lease-1", to: target)
        XCTAssertTrue(first.answer.hasPrefix("HTTP/1.1 200 "), first.answer)
        let sameLease = hold(port, lease: "lease-1", to: target)
        XCTAssertTrue(sameLease.answer.hasPrefix("HTTP/1.1 503 "), "one lease's cap: \(sameLease.answer)")
        close(sameLease.socket)
        // The 503's stream ends: the cap on all of them has room again.
        var other = (socket: Int32(-1), answer: "")
        for _ in 0..<50 {
            other = hold(port, lease: "lease-2", to: target)
            if other.answer.hasPrefix("HTTP/1.1 200 ") { break }
            close(other.socket)
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(other.answer.hasPrefix("HTTP/1.1 200 "), other.answer)
        let third = hold(port, lease: "lease-3", to: target)
        XCTAssertEqual(third.answer, "", "past the cap on all of them: closed unanswered")
        close(third.socket)
        XCTAssertTrue(lines.all.contains("relay: 2 streams at once already: new ones closed"), "\(lines.all)")
        XCTAssertTrue(lines.all.contains("relay: container:lease-1 has 1 streams at once already: new ones refused"), "\(lines.all)")
        // The first lease's stream ended: room for it again.
        close(first.socket)
        var again = (socket: Int32(-1), answer: "")
        for _ in 0..<50 {
            again = hold(port, lease: "lease-1", to: target)
            if again.answer.hasPrefix("HTTP/1.1 200 ") { break }
            close(again.socket)
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(again.answer.hasPrefix("HTTP/1.1 200 "), again.answer)
        close(again.socket)
        close(other.socket)
    }

    /// NCH's review of #414 (a lockout): streams still reading the relay's
    /// header have a cap of their own, below the one on all, so streams that
    /// never say who they are can't hold every place; past it a new one is
    /// closed at once, and a named stream still comes in once one goes.
    func testStreamsWithoutTheirHeaderHaveACapOfTheirOwn() throws {
        guard let echo = Echo() else { throw XCTSkip("no port for the server") }
        defer { echo.stop() }
        let (relay, port, _, lines) = try relay(maxUnnamed: 2, headerTimeout: 3)
        defer { relay.stop() }
        let silent = (0..<2).map { _ in agent_proxy_connect_tcp("127.0.0.1", UInt16(port)) }
        XCTAssertTrue(silent.allSatisfy { $0 >= 0 })
        Thread.sleep(forTimeInterval: 0.3)
        let third = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        XCTAssertGreaterThanOrEqual(third, 0)
        agent_proxy_set_receive_timeout(third, 5)
        let started = Date()
        var byte: UInt8 = 0
        XCTAssertEqual(read(third, &byte, 1), 0, "past the cap on unnamed streams: closed unanswered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "at once, not at the header's deadline")
        close(third)
        XCTAssertTrue(lines.all.contains("relay: 2 streams still without their header: new ones closed"), "\(lines.all)")
        // One of them goes: a named stream comes in.
        close(silent[0])
        var named = (socket: Int32(-1), answer: "")
        for _ in 0..<50 {
            named = hold(port, lease: "lease-1", to: "127.0.0.1:\(echo.port)")
            if named.answer.hasPrefix("HTTP/1.1 200 ") { break }
            close(named.socket)
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(named.answer.hasPrefix("HTTP/1.1 200 "), named.answer)
        close(named.socket)
        close(silent[1])
    }

    /// The header has its deadline in all (2 seconds by default), however
    /// it's dribbled in: a byte now and then doesn't hold the stream.
    func testAHeaderDribbledInIsClosedAtItsDeadline() throws {
        let (relay, port, _, lines) = try relay(headerTimeout: 1)
        defer { relay.stop() }
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        XCTAssertGreaterThanOrEqual(socket, 0)
        let header = Self.header
        let written = DispatchSemaphore(value: 0)
        let writer = Thread {
            defer { written.signal() }
            for byte in header {
                var one = byte
                if write(socket, &one, 1) != 1 { return }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        // The writer done (its write refused once the stream is closed) before the descriptor is let go.
        defer {
            _ = written.wait(timeout: .now() + 15)
            close(socket)
        }
        writer.start()
        agent_proxy_set_receive_timeout(socket, 10)
        let started = Date()
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(read(socket, &byte, 1), 0, "closed at the header's deadline")
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, 3, "the deadline is the whole header's, not each read's")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("relay: a stream without the relay's header") }, "\(lines.all)")
    }

    /// One lease's cap below the one on all, and the unnamed streams' too,
    /// or shireworks-agent-proxy doesn't start.
    func testTheCapsMustLeaveRoomForOthers() {
        XCTAssertNil(RelayListener.capsProblem(maxConnections: 512, maxConnectionsPerLease: 128))
        XCTAssertNotNil(RelayListener.capsProblem(maxConnections: 128, maxConnectionsPerLease: 128))
        XCTAssertNotNil(RelayListener.capsProblem(maxConnections: 100, maxConnectionsPerLease: 200))
        XCTAssertNotNil(RelayListener.capsProblem(maxConnections: 64, maxConnectionsPerLease: 8), "the unnamed streams' 64 fill it")
        XCTAssertNil(RelayListener.capsProblem(maxConnections: 64, maxConnectionsPerLease: 8, maxUnnamed: 16))
    }

    /// The header has `headerTimeout` (2 seconds) and the request's head
    /// `headTimeout`; a tunnel, once open, may be quiet for longer.
    func testAStreamThatSaysNothingIsClosedAndAnOpenTunnelMayBeQuiet() throws {
        guard let echo = Echo() else { throw XCTSkip("no port for the server") }
        defer { echo.stop() }
        let (relay, port, _, _) = try relay(headTimeout: 1)
        defer { relay.stop() }
        for prefix in [[UInt8](), Self.header] {
            let silent = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
            XCTAssertGreaterThanOrEqual(silent, 0)
            _ = prefix.withUnsafeBytes { write(silent, $0.baseAddress, $0.count) }
            agent_proxy_set_receive_timeout(silent, 8)
            let started = Date()
            var byte: UInt8 = 0
            XCTAssertEqual(read(silent, &byte, 1), 0, "closed by the relay listener")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            close(silent)
        }
        let tunnel = hold(port, lease: "lease-1", to: "127.0.0.1:\(echo.port)")
        defer { close(tunnel.socket) }
        XCTAssertTrue(tunnel.answer.hasPrefix("HTTP/1.1 200 "), tunnel.answer)
        Thread.sleep(forTimeInterval: 2)
        _ = Array("still here".utf8).withUnsafeBytes { write(tunnel.socket, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { read(tunnel.socket, $0.baseAddress, $0.count) }
        XCTAssertEqual(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self), "still here")
    }

    func testAStreamWhoseLeaseIDIsntOneIsClosedUnanswered() throws {
        let (relay, port, egress, lines) = try relay()
        defer { relay.stop() }
        let header = ProxyProtocolHeader.relayed(lease: "lease\r\nX-Injected: 1", relayToken: Self.relayToken).encoded()
        XCTAssertEqual(send(header + Array("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8), to: port), "")
        XCTAssertTrue(lines.all.contains("relay: a stream whose lease id isn't one: closed"), "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.contains("X-Injected") }, "\(lines.all)")
        XCTAssertEqual(egress.entries(), [])
    }

    /// DNS over HTTPS takes at most 64 KB; plain HTTP's body is streamed on,
    /// at most 16 MB.
    func testBodiesAreBounded() throws {
        let dns = DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("10.0.0.1")], fallbacks: []) }, exchange: NameExchange())
        guard let counter = Counter() else { throw XCTSkip("no port for the server") }
        defer { counter.stop() }
        let (relay, port, _, _) = try relay(dns: dns)
        defer { relay.stop() }
        let bigQuery = send(Self.header + Array("POST /dns-query HTTP/1.1\r\nContent-Type: application/dns-message\r\nContent-Length: 70000\r\n\r\n".utf8),
                            to: port)
        XCTAssertTrue(bigQuery.hasPrefix("HTTP/1.1 413 "), bigQuery)
        let huge = send(Self.header + Array("POST http://127.0.0.1:\(counter.port)/ HTTP/1.1\r\nContent-Length: \(16 << 20 + 1)\r\n\r\n".utf8), to: port)
        XCTAssertTrue(huge.hasPrefix("HTTP/1.1 413 "), huge)
        // 200 KB: past what the listener holds, streamed on whole.
        let body = [UInt8](repeating: 0x61, count: 200 << 10)
        let streamed = send(Self.header + Array("POST http://127.0.0.1:\(counter.port)/ HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body,
                            to: port)
        XCTAssertTrue(streamed.hasSuffix("got \(body.count)"), streamed)
    }

    func testAContainersDNSQueryIsAnsweredOverDoH() throws {
        let dns = DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("10.0.0.1")], fallbacks: []) }, exchange: NameExchange())
        let (relay, port, _, _) = try relay(dns: dns)
        defer { relay.stop() }
        let query = try XCTUnwrap(DNSMessage.query(id: 0x4242, name: "archive.ubuntu.com"))
        let post = Array("POST /dns-query HTTP/1.1\r\nContent-Type: application/dns-message\r\nContent-Length: \(query.bytes.count)\r\n\r\n".utf8)
        let heard = sendBytes(Self.header + post + query.bytes, to: port)
        let blank = Array("\r\n\r\n".utf8)
        XCTAssertGreaterThan(heard.count, 4)
        let end = try XCTUnwrap((0...(max(heard.count, 4) - 4)).first { Array(heard[$0..<($0 + 4)]) == blank })
        let head = String(decoding: heard[..<end], as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 "), head)
        XCTAssertTrue(head.contains("Content-Type: application/dns-message"), head)
        let answer = try XCTUnwrap(DNSMessage(Array(heard[(end + 4)...])))
        XCTAssertEqual(answer.id, 0x4242)
        XCTAssertTrue(answer.isResponse)
        XCTAssertEqual(answer.name, "archive.ubuntu.com")
    }
}

/// An upstream that answers every query: no error, nothing else.
private struct NameExchange: DNSExchanging {
    func exchange(_ query: DNSMessage, with upstream: DNSUpstream, timeout: Duration) async throws -> DNSMessage {
        query.answer(.noError)
    }
}

/// An MCP proxy, played: it keeps each call and answers "ok".
private final class FakeMCP: MCPAnswering {
    let heard = Locked<[String]>([])

    func answerMCP(_ stream: Int32, _ request: HTTPRequest, caller: EgressProxy.Caller) {
        heard.withLock { $0.append("\(caller.lease) \(request.method) \(request.path) \(String(decoding: request.body, as: UTF8.self))") }
        HTTPRequest.send(stream, Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
    }
}
