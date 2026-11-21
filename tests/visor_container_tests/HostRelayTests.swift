// HostRelay, the container's way out on the host: against a fake
// agent-proxy relay, each connection on its Unix socket is a TCP stream to
// the relay port, begun with the PROXY v2 header (TLV 0xE1 `visor-sessions`,
// TLV 0xE2 the relay's token, byte for byte) and then spliced both ways;
// with no token, or no agent-proxy, the guest's stream is closed. And
// against agent-proxy's own relay listener, `relay-client check`'s health
// answer comes back through it (RelayHealthCheck), and not with a wrong
// token.

import CAgentProxyPOSIX
import Foundation
import Synchronization
import Testing
import VisorAgentProxy
import VisorContainerCore

@Suite struct HostRelayTests {
    /// A short folder for a socket (a socket's path must be under 104 bytes).
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/vhr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fake relay listener: it reads the PROXY header, keeps it, answers
    /// "header ok\n", then echoes what comes. Its port, and what it heard.
    final class FakeRelay: Sendable {
        let port: Int
        private let listener: Int32
        let headers = Mutex<[ProxyProtocolHeader]>([])
        let raw = Mutex<[[UInt8]]>([])

        init?() {
            for _ in 0..<20 {
                let port = Int.random(in: 20000...45000)
                let listener = agent_proxy_listen(UInt16(port), 0)
                guard listener >= 0 else { continue }
                self.port = port
                self.listener = listener
                return
            }
            return nil
        }

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    let stream = agent_proxy_accept(listener)
                    if stream < 0 { return }
                    Thread.detachNewThread { [self] in serve(stream) }
                }
            }
        }

        private func serve(_ stream: Int32) {
            defer { close(stream) }
            var fixed = [UInt8](repeating: 0, count: 16)
            guard readExactly(stream, &fixed) else { return }
            var rest = [UInt8](repeating: 0, count: Int(fixed[14]) << 8 | Int(fixed[15]))
            guard readExactly(stream, &rest) else { return }
            raw.withLock { $0.append(fixed + rest) }
            guard let header = try? ProxyProtocolHeader.parse(fixed + rest).header else { return }
            headers.withLock { $0.append(header) }
            let ok = Array("header ok\n".utf8)
            _ = ok.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
                if count <= 0 { return }
                _ = buffer.withUnsafeBytes { write(stream, $0.baseAddress, count) }
            }
        }

        private func readExactly(_ stream: Int32, _ bytes: inout [UInt8]) -> Bool {
            var got = 0
            while got < bytes.count {
                let count = bytes.withUnsafeMutableBytes { read(stream, $0.baseAddress! + got, $0.count - got) }
                if count <= 0 { return false }
                got += count
            }
            return true
        }

        func stop() {
            agent_proxy_shutdown(listener)
            close(listener)
        }
    }

    /// Writes `text` on a new connection to the relay's socket, ends its
    /// sending half, and reads everything that comes back.
    private func exchange(_ path: String, _ text: String) -> String {
        let stream = agent_proxy_connect_unix(path)
        guard stream >= 0 else { return "<no connection>" }
        defer { close(stream) }
        agent_proxy_set_receive_timeout(stream, 5)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(stream, $0.baseAddress, $0.count) }
        agent_proxy_shutdown_write(stream)
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(stream, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
        }
        return String(decoding: heard, as: UTF8.self)
    }

    @Test func theHeaderIsProxyV2WithTheLeaseAndTheToken() {
        let lease = Array("visor-sessions".utf8), token = Array("relay-secret".utf8)
        let tlvs: [UInt8] = [0xE1, 0, UInt8(lease.count)] + lease + [0xE2, 0, UInt8(token.count)] + token
        let expected: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A, 0x21, 0x00, 0, UInt8(tlvs.count)] + tlvs
        #expect(HostRelay.header(token: "relay-secret") == expected)
        let parsed = try? ProxyProtocolHeader.parse(expected).header
        #expect(parsed?.admittedLease(relayToken: "relay-secret") == "visor-sessions")
    }

    @Test func eachConnectionIsHeadedThenSplicedToTheRelayPort() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = try #require(FakeRelay())
        fake.start()
        defer { fake.stop() }
        let socket = folder.appendingPathComponent("relay.sock").path
        let relay = HostRelay(socketPath: socket, port: fake.port, token: { "relay-secret" })
        try relay.start()
        defer { relay.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700, "the socket's folder is this user's alone")
        #expect(exchange(socket, "CONNECT github.com:443 HTTP/1.1\r\n\r\n") == "header ok\nCONNECT github.com:443 HTTP/1.1\r\n\r\n")
        #expect(exchange(socket, "a second stream") == "header ok\na second stream")
        #expect(fake.raw.withLock { $0 } == [HostRelay.header(token: "relay-secret"), HostRelay.header(token: "relay-secret")])
        #expect(fake.headers.withLock { $0.map { $0.leaseID } } == ["visor-sessions", "visor-sessions"])
    }

    @Test func theTokenIsReadForEachConnection() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = try #require(FakeRelay())
        fake.start()
        defer { fake.stop() }
        let token = Mutex<String?>("first")
        let socket = folder.appendingPathComponent("relay.sock").path
        let relay = HostRelay(socketPath: socket, port: fake.port, token: { token.withLock { $0 } })
        try relay.start()
        defer { relay.stop() }
        _ = exchange(socket, "x")
        token.withLock { $0 = "second" }
        _ = exchange(socket, "y")
        #expect(fake.raw.withLock { $0 } == [HostRelay.header(token: "first"), HostRelay.header(token: "second")])
        // None: the stream is closed, and nothing reaches agent-proxy.
        token.withLock { $0 = nil }
        #expect(exchange(socket, "z") == "")
        #expect(fake.raw.withLock { $0.count } == 2)
    }

    @Test func noAgentProxyClosesTheStream() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = try #require(FakeRelay())
        let port = fake.port
        fake.stop()
        let socket = folder.appendingPathComponent("relay.sock").path
        let lines = Mutex<[String]>([])
        let relay = HostRelay(socketPath: socket, port: port, token: { "relay-secret" }, log: { line in lines.withLock { $0.append(line) } })
        try relay.start()
        defer { relay.stop() }
        #expect(exchange(socket, "CONNECT x:1 HTTP/1.1\r\n\r\n") == "")
        #expect(lines.withLock { $0.contains { $0.contains("didn't answer") } })
    }

    @Test func stoppedItTakesNoMoreAndItsSocketIsGone() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("relay.sock").path
        let relay = HostRelay(socketPath: socket, port: 1, token: { "t" })
        try relay.start()
        #expect(FileManager.default.fileExists(atPath: socket))
        relay.stop()
        #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(agent_proxy_connect_unix(socket) < 0)
    }

    @Test func aSocketPathTooLongIsRefused() throws {
        let relay = HostRelay(socketPath: "/tmp/" + String(repeating: "x", count: 120) + "/relay.sock", port: 1, token: { "t" })
        #expect(throws: HostRelayError.self) { try relay.start() }
    }

    /// agent-proxy's own relay listener, before an egress proxy that
    /// reaches nothing.
    private func listener(token: String) throws -> (RelayListener, Int) {
        let proxy = EgressProxy(connect: { _ in -1 }, egress: nil, log: { _ in })
        for _ in 0..<20 {
            let port = Int.random(in: 20000...45000)
            if let relay = RelayListener(port: port, relayToken: { token }, proxy: proxy, log: { _ in }) {
                relay.start()
                return (relay, port)
            }
        }
        throw HostRelayError(path: "no port", errno: EADDRINUSE)
    }

    @Test func relayClientsHealthCheckPassesThroughItToAgentProxy() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (proxy, port) = try listener(token: "relay-secret")
        defer { proxy.stop() }
        let socket = folder.appendingPathComponent("relay.sock").path
        let relay = HostRelay(socketPath: socket, port: port, token: { "relay-secret" })
        try relay.start()
        defer { relay.stop() }
        let (ok, line) = RelayHealthCheck.run(path: socket, timeout: 5)
        #expect(ok, "\(line)")
        #expect(line.contains("agent-proxy answers"))
    }

    @Test func relayClientsHealthCheckFailsWithAnotherToken() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (proxy, port) = try listener(token: "relay-secret")
        defer { proxy.stop() }
        let socket = folder.appendingPathComponent("relay.sock").path
        let relay = HostRelay(socketPath: socket, port: port, token: { "not-the-token" })
        try relay.start()
        defer { relay.stop() }
        let (ok, line) = RelayHealthCheck.run(path: socket, timeout: 5)
        #expect(!ok)
        #expect(line.contains("closed without an answer"))
    }

    @Test func aFreeLoopbackPortIsSeenSo() throws {
        let fake = try #require(FakeRelay())
        defer { fake.stop() }
        #expect(!LoopbackPort.isFree(fake.port), "one listened on")
        #expect(!LoopbackPort.isFree(0) && !LoopbackPort.isFree(70000))
    }
}
