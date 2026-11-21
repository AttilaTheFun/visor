// relay-client's pieces, without a network namespace: the fake
import Synchronization
// addresses both ways and their going round; the resolver's answers (a fake
// address, none for AAAA, the rest asked of agent-proxy); the relay's CONNECT
// and DoH; a redirected connection sent on by name; and the setup's
// commands.

import CRelayClientPOSIX
import Foundation
import VisorAgentProxy
@testable import VisorRelayClient
import XCTest

final class ClientTests: XCTestCase {
    func testANameKeepsItsAddressAndTheAddressGivesTheNameBack() {
        let addresses = FakeAddresses()
        let github = addresses.address(for: "GitHub.com")
        XCTAssertEqual(github, [198, 18, 0, 2])
        XCTAssertEqual(addresses.address(for: "github.com"), github)
        XCTAssertEqual(addresses.address(for: "example.com"), [198, 18, 0, 3])
        XCTAssertEqual(addresses.name(for: "198.18.0.2"), "github.com")
        XCTAssertNil(addresses.name(for: "198.18.0.9"))
        XCTAssertNil(addresses.name(for: "93.184.216.34"))
        XCTAssertNil(addresses.name(for: FakeAddresses.source))
    }

    func testAddressesGoRoundAndTheOldNameLosesItsOwn() {
        let addresses = FakeAddresses(size: 2)
        XCTAssertEqual(addresses.address(for: "a"), [198, 18, 0, 2])
        XCTAssertEqual(addresses.address(for: "b"), [198, 18, 0, 3])
        XCTAssertEqual(addresses.address(for: "c"), [198, 18, 0, 2])
        XCTAssertEqual(addresses.name(for: "198.18.0.2"), "c")
        XCTAssertEqual(addresses.address(for: "a"), [198, 18, 0, 3], "a asks again: the next one")
        XCTAssertEqual(addresses.name(for: "198.18.0.3"), "a")
    }

    func testTheResolverGivesFakeAddressesNoneForIPv6AndAsksAgentProxyTheRest() async throws {
        let addresses = FakeAddresses()
        let asked = AskedQueries()
        let resolver = ClientResolver(addresses: addresses) { bytes in
            asked.add(bytes)
            return DNSMessage(bytes)?.answer(.nameError).with(id: 0x9999).bytes
        }
        let a = try XCTUnwrap(DNSMessage.query(id: 7, name: "registry.npmjs.org"))
        let answeredA = await resolver.answer(a)
        let answered = try XCTUnwrap(answeredA)
        XCTAssertEqual(answered.id, 7)
        XCTAssertTrue(answered.isResponse)
        XCTAssertEqual(answered.code, .noError)
        XCTAssertEqual(Array(answered.bytes.suffix(4)), addresses.address(for: "registry.npmjs.org"))
        XCTAssertEqual(answered.bytes[6...7], [0, 1], "one answer")

        let localhostQuery = try XCTUnwrap(DNSMessage.query(id: 8, name: "localhost"))
        let localhostAnswer = await resolver.answer(localhostQuery)
        let localhost = try XCTUnwrap(localhostAnswer)
        XCTAssertEqual(Array(localhost.bytes.suffix(4)), [127, 0, 0, 1])

        let aaaaQuery = try XCTUnwrap(DNSMessage.query(id: 9, name: "github.com", type: 28))
        let aaaaAnswer = await resolver.answer(aaaaQuery)
        let aaaa = try XCTUnwrap(aaaaAnswer)
        XCTAssertEqual(aaaa.code, .noError)
        XCTAssertEqual(aaaa.bytes[6...7], [0, 0], "no answer")

        let mx = try XCTUnwrap(DNSMessage.query(id: 10, name: "example.com", type: 15))
        let relayedAnswer = await resolver.answer(mx)
        let relayed = try XCTUnwrap(relayedAnswer)
        XCTAssertEqual(relayed.code, .nameError)
        XCTAssertEqual(relayed.id, 10, "under the query's id")
        XCTAssertEqual(asked.all, [mx.bytes])
        XCTAssertTrue(asked.all.count == 1, "only what it can't answer itself")

        let failing = ClientResolver(addresses: addresses) { _ in nil }
        let failedAnswer = await failing.answer(mx)
        let failed = try XCTUnwrap(failedAnswer)
        XCTAssertEqual(failed.code, .serverFailure)
    }

    func testTheRelaysConnectAndDNS() throws {
        let relay = try XCTUnwrap(FakeRelay(refused: ["nowhere.example"]) { query in DNSMessage(query)?.answer(.nameError).bytes })
        defer { relay.stop() }
        let dialer = RelayDialer(path: relay.path)
        let stream = try XCTUnwrap(dialer.open(host: "github.com", port: 443))
        defer { close(stream) }
        RelayDialer.send(stream, Array("PING".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
        XCTAssertEqual(String(decoding: buffer[0..<max(count, 0)], as: UTF8.self), "PONG PING")

        var problems: [String] = []
        XCTAssertNil(dialer.open(host: "nowhere.example", port: 443) { problems.append($0) })
        XCTAssertEqual(problems, ["CONNECT nowhere.example:443: HTTP/1.1 502 Bad Gateway"])

        let query = try XCTUnwrap(DNSMessage.query(id: 3, name: "example.com", type: 16))
        let answer = try XCTUnwrap(dialer.query(query.bytes).flatMap(DNSMessage.init))
        XCTAssertEqual(answer.code, .nameError)
        XCTAssertEqual(relay.heard.withLock { $0 }, ["CONNECT github.com:443 HTTP/1.1", "CONNECT nowhere.example:443 HTTP/1.1",
                                                    "POST /dns-query HTTP/1.1"])
        XCTAssertNil(RelayDialer(path: relay.path + ".missing").open(host: "github.com", port: 443))
    }

    func testARedirectedConnectionGoesOnByName() throws {
        let relay = try XCTUnwrap(FakeRelay())
        defer { relay.stop() }
        let addresses = FakeAddresses()
        let fake = addresses.address(for: "api.github.com").map(String.init).joined(separator: ".")
        let target = Target()
        let listener = try XCTUnwrap(RedirectListener(port: 0, addresses: addresses, relay: RelayDialer(path: relay.path),
                                                      destination: { _ in target.value }, log: { _ in }))
        listener.start()
        defer { listener.stop() }

        func call() -> String {
            let socket = relay_client_connect_tcp("127.0.0.1", listener.port)
            guard socket >= 0 else { return "" }
            defer { close(socket) }
            RelayDialer.send(socket, Array("PING".utf8))
            var heard: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                heard += buffer[0..<count]
            }
            return String(decoding: heard, as: UTF8.self)
        }

        target.value = (fake, 443)
        XCTAssertEqual(call(), "PONG PING")
        target.value = ("140.82.112.3", 22)
        XCTAssertEqual(call(), "PONG PING", "an address no name was given goes on as itself")
        target.value = ("127.0.0.1", listener.port)
        XCTAssertEqual(call(), "", "loopback is never relayed")
        XCTAssertEqual(relay.heard.withLock { $0 }, ["CONNECT api.github.com:443 HTTP/1.1", "CONNECT 140.82.112.3:22 HTTP/1.1"])
    }

    /// A listener on loopback, at a port the system picked (not one picked
    /// at random, which a test run beside it could pick too), whose
    /// connections are closed at once, or held.
    private func listener(closing: Bool) throws -> (port: UInt16, stop: () -> Void) {
        let socket = relay_client_listen(0, 0)
        guard socket >= 0 else { throw XCTSkip("no port") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else {
            close(socket)
            throw XCTSkip("no port")
        }
        Thread.detachNewThread {
            var held: [Int32] = []
            while true {
                let connection = relay_client_accept(socket)
                if connection < 0 { break }
                if closing { close(connection) } else { held.append(connection) }
            }
            held.forEach { close($0) }
        }
        return (UInt16(bigEndian: bound.sin_port), { relay_client_shutdown(socket); close(socket) })
    }

    func testCheckSaysConnectedOnlyWhenTheConnectionHolds() throws {
        let closing = try listener(closing: true)
        defer { closing.stop() }
        let refused = try XCTUnwrap(ConnectionCheck.run("127.0.0.1:\(closing.port)", send: nil, timeout: 5, settle: 1))
        XCTAssertFalse(refused.ok, "\(refused.lines)")
        XCTAssertTrue(refused.lines.last?.contains("not connected") ?? false, "\(refused.lines)")

        let holding = try listener(closing: false)
        defer { holding.stop() }
        let held = try XCTUnwrap(ConnectionCheck.run("127.0.0.1:\(holding.port)", send: nil, timeout: 5, settle: 1))
        XCTAssertTrue(held.ok, "\(held.lines)")
        XCTAssertEqual(held.lines.last, "connected to 127.0.0.1:\(holding.port)")
    }

    func testSpawnRunsWithInputAndHearsErrorsAndStatus() {
        let echoed = Spawn.run(["sh", "-c", "cat >&2; echo out; exit 4"], input: "to standard error")
        XCTAssertEqual(echoed.status, 4)
        XCTAssertEqual(echoed.errors, "to standard error")
        XCTAssertEqual(Spawn.run(["sh", "-c", "kill -TERM $$"]).status, 128 + SIGTERM)
        XCTAssertEqual(Spawn.run(["no-such-program-here"]).status, 127)
        let started = Spawn.start(["sh", "-c", "exit 7"])
        XCTAssertNotNil(started)
        XCTAssertEqual(started.map(Spawn.wait), 7)
        XCTAssertEqual(Spawn.locate("sh", path: "/nowhere:/bin"), "/bin/sh")
        XCTAssertNil(Spawn.locate("sh", path: "/nowhere"))
    }

    func testTheRuleAsShown() {
        let rules = ContainerNetwork.ruleset(listenerPort: 15001)
        XCTAssertTrue(rules.contains("meta l4proto tcp redirect to :15001"))
        XCTAssertTrue(rules.contains("ip daddr 127.0.0.0/8 return"))
    }

    /// The real thing, where this system lets a test make a user and network
    /// namespace (unshare -rnm): the client sets the network up over netlink
    /// with no `ip` or `nft`, and `check` resolves a name and connects to it
    /// as any program would, through the relay. A temporary file is mounted
    /// over /etc/resolv.conf inside, so the system's own is never written.
    func testInANamespaceWithNoNetworkAConnectionGoesThroughTheRelayByName() throws {
        // Beside the tests: the bundle's folder, or the test runner's.
        let folders = [Bundle(for: Self.self).bundleURL.deletingLastPathComponent(), Bundle.main.executableURL?.deletingLastPathComponent()]
        guard let client = folders.compactMap({ $0?.appendingPathComponent("relay-client").path })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { throw XCTSkip("no relay-client built beside the tests") }
        guard Spawn.run(["unshare", "-rnm", "true"]).status == 0 else { throw XCTSkip("no user and network namespaces here") }
        let relay = try XCTUnwrap(FakeRelay())
        defer { relay.stop() }
        let resolver = FileManager.default.temporaryDirectory.appendingPathComponent("resolv-\(UUID().uuidString.prefix(8)).conf")
        try Data("nameserver 192.0.2.1\n".utf8).write(to: resolver)
        defer { try? FileManager.default.removeItem(at: resolver) }
        let script = "set -e; mount --bind \(resolver.path) /etc/resolv.conf; "
            + "exec \(client) run --relay \(relay.path) -- \(client) check registry.npmjs.org:443 --send PING"
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["unshare", "-rnm", "sh", "-c", script]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, said)
        XCTAssertTrue(said.contains("registry.npmjs.org is 198.18.0.2"), said)
        XCTAssertTrue(said.contains("heard: PONG PING"), said)
        XCTAssertEqual(relay.heard.withLock { $0 }, ["CONNECT registry.npmjs.org:443 HTTP/1.1"])
        XCTAssertEqual(try String(contentsOf: resolver, encoding: .utf8), ContainerNetwork.resolvConf, "written inside, on the mount")
    }
}

/// The queries the resolver asked of agent-proxy.
private final class AskedQueries: Sendable {
    private let queries = Mutex<[[UInt8]]>([])
    func add(_ query: [UInt8]) { queries.withLock { $0.append(query) } }
    var all: [[UInt8]] { queries.withLock { $0 } }
}

/// The original destination a test gives the listener.
private final class Target: Sendable {
    private let destination = Mutex<(host: String, port: UInt16)?>(nil)
    var value: (host: String, port: UInt16)? {
        get { destination.withLock { $0 } }
        set { destination.withLock { $0 = newValue } }
    }
}
