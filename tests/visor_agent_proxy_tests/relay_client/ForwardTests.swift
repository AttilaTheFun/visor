// relay-client's `--forward <port>=<socket>` (Visor's driver link): the
// loopback listener joins each connection to the Unix socket, and a socket
// that doesn't answer closes it; what `--forward` takes; and loopback never
// redirected by the nat chain (ContainerNetwork.excluded, the address the
// forwards listen on), with, where this system lets a test make a network
// namespace, the real thing: a forward inside relay-client's network whose
// connection never reaches the relay.

import CRelayClientPOSIX
import Foundation
import Synchronization
import VisorAgentProxy
@testable import VisorRelayClient
import XCTest

final class ForwardTests: XCTestCase {
    /// A Unix socket that answers "PONG <what it read>" once a connection,
    /// then closes it. Its path, and how to stop it.
    private func unixEcho() throws -> (path: String, stop: () -> Void) {
        let path = "/tmp/rcf-\(UUID().uuidString.prefix(8)).sock"
        let listener = relay_client_listen_unix(path)
        guard listener >= 0 else { throw XCTSkip("no Unix socket at \(path)") }
        Thread.detachNewThread {
            while true {
                let connection = relay_client_accept(listener)
                if connection < 0 { break }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 256)
                    let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                    if count > 0 { RelayDialer.send(connection, Array("PONG ".utf8) + buffer[0..<count]) }
                    close(connection)
                }
            }
        }
        return (path, {
            relay_client_shutdown(listener)
            close(listener)
            unlink(path)
        })
    }

    /// What 127.0.0.1:`port` answers "PING" with, read to its end.
    private func call(_ port: UInt16) -> String {
        let socket = relay_client_connect_tcp("127.0.0.1", port)
        guard socket >= 0 else { return "(not connected)" }
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

    func testALoopbackPortIsJoinedToTheUnixSocket() throws {
        let echo = try unixEcho()
        defer { echo.stop() }
        let forward = try XCTUnwrap(LoopbackForward(LoopbackForward.Spec(port: 0, socket: echo.path), log: { _ in }))
        forward.start()
        defer { forward.stop() }
        XCTAssertNotEqual(forward.port, 0)
        XCTAssertEqual(call(forward.port), "PONG PING")
        XCTAssertEqual(call(forward.port), "PONG PING", "each connection a connection to the socket")
    }

    func testASocketThatDoesNotAnswerClosesTheConnection() throws {
        let lines = Mutex<[String]>([])
        let missing = "/tmp/rcf-\(UUID().uuidString.prefix(8))-missing.sock"
        let forward = try XCTUnwrap(LoopbackForward(LoopbackForward.Spec(port: 0, socket: missing), log: { line in lines.withLock { $0.append(line) } }))
        forward.start()
        defer { forward.stop() }
        XCTAssertEqual(call(forward.port), "")
        XCTAssertTrue(lines.withLock { $0.contains { $0.contains("\(missing) didn't answer") } }, "\(lines.withLock { $0 })")
    }

    func testWhatForwardTakes() {
        XCTAssertEqual(LoopbackForward.Spec("7434=/run/visor/driver.sock"), LoopbackForward.Spec(port: 7434, socket: "/run/visor/driver.sock"))
        XCTAssertEqual(LoopbackForward.Spec("7434=/run/visor/driver.sock")?.description, "127.0.0.1:7434 to /run/visor/driver.sock")
        for refused in ["7434", "=/run/visor/driver.sock", "0=/run/x.sock", "70000=/run/x.sock", "7434=run/x.sock", "7434=", "port=/x"] {
            XCTAssertNil(LoopbackForward.Spec(refused), refused)
        }
        let driver = LoopbackForward.Spec(port: 7434, socket: "/run/visor/driver.sock")
        XCTAssertNil(RelayClientCommand.clash([driver], listenerPort: 15001))
        XCTAssertEqual(RelayClientCommand.clash([LoopbackForward.Spec(port: 15001, socket: "/x")], listenerPort: 15001), 15001)
        XCTAssertEqual(RelayClientCommand.clash([LoopbackForward.Spec(port: 53, socket: "/x")], listenerPort: 15001), 53)
        XCTAssertEqual(RelayClientCommand.clash([driver, driver], listenerPort: 15001), 7434)
    }

    func testLoopbackIsNeverRedirectedAndEverythingElseIs() {
        XCTAssertFalse(ContainerNetwork.isRedirected(LoopbackForward.address), "the forwards listen where the chain returns")
        for loopback in ["127.0.0.1", "127.0.0.53", "127.255.255.254", "127.1.2.3"] {
            XCTAssertFalse(ContainerNetwork.isRedirected(loopback), loopback)
        }
        for elsewhere in ["198.18.0.2", "128.0.0.1", "126.255.255.255", "10.0.0.1", "192.168.1.1", "140.82.112.3", "0.0.0.0"] {
            XCTAssertTrue(ContainerNetwork.isRedirected(elsewhere), elsewhere)
        }
        for notAnAddress in ["", "127", "127.0.0", "127.0.0.1.5", "127.0.0.256", "localhost", "::1"] {
            XCTAssertTrue(ContainerNetwork.isRedirected(notAnAddress), "\(notAnAddress): not IPv4, so not loopback's")
        }
        XCTAssertEqual(ContainerNetwork.mask(prefix: 8), [255, 0, 0, 0])
        XCTAssertEqual(ContainerNetwork.mask(prefix: 0), [0, 0, 0, 0])
        XCTAssertEqual(ContainerNetwork.mask(prefix: 20), [255, 255, 240, 0])
        XCTAssertEqual(ContainerNetwork.mask(prefix: 32), [255, 255, 255, 255])
        XCTAssertEqual(ContainerNetwork.mask(prefix: 40), [255, 255, 255, 255])
        XCTAssertEqual(ContainerNetwork.excluded.network, [127, 0, 0, 0])
        XCTAssertEqual(ContainerNetwork.excluded.prefix, 8)

        // The rule as written: the return first, then the redirect.
        let rules = ContainerNetwork.ruleset(listenerPort: 15001)
        let returned = rules.range(of: "ip daddr 127.0.0.0/8 return")
        let redirected = rules.range(of: "meta l4proto tcp redirect to :15001")
        XCTAssertNotNil(returned)
        XCTAssertNotNil(redirected)
        if let returned, let redirected { XCTAssertLessThan(returned.lowerBound, redirected.lowerBound, rules) }
    }

    /// The real thing, where this system lets a test make a user and network
    /// namespace (unshare -rnm): relay-client sets the network up (the nat
    /// chain and its loopback return), forwards 7434 to a Unix socket, and a
    /// connection to 127.0.0.1:7434 reaches the socket while the relay hears
    /// nothing of it.
    func testInANamespaceTheForwardIsNotRelayed() throws {
        let folders = [Bundle(for: Self.self).bundleURL.deletingLastPathComponent(), Bundle.main.executableURL?.deletingLastPathComponent()]
        guard let client = folders.compactMap({ $0?.appendingPathComponent("relay-client").path })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { throw XCTSkip("no relay-client built beside the tests") }
        guard Spawn.run(["unshare", "-rnm", "true"]).status == 0 else { throw XCTSkip("no user and network namespaces here") }
        let relay = try XCTUnwrap(FakeRelay())
        defer { relay.stop() }
        let echo = try unixEcho()
        defer { echo.stop() }
        let resolver = FileManager.default.temporaryDirectory.appendingPathComponent("resolv-\(UUID().uuidString.prefix(8)).conf")
        try Data("nameserver 192.0.2.1\n".utf8).write(to: resolver)
        defer { try? FileManager.default.removeItem(at: resolver) }
        let script = "set -e; mount --bind \(resolver.path) /etc/resolv.conf; "
            + "exec \(client) run --relay \(relay.path) --forward 7434=\(echo.path) -- \(client) check 127.0.0.1:7434 --send PING"
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
        XCTAssertTrue(said.contains("heard: PONG PING"), said)
        XCTAssertEqual(relay.heard.withLock { $0 }, [], "loopback's forward never goes through the relay")
    }
}
