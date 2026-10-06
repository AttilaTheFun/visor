// SSH against a real `sshd`, over the native service: run by hand with
// VISOR_SSH_ADDRESS set to `user@host:port` of an sshd whose authorized
// keys file is VISOR_SSH_AUTHORIZED_KEYS (a throwaway sshd started for
// the probe: docs/DEVELOPMENT.md), and a Visor server on that computer's
// loopback (VISOR_SSH_PASSWORD its password, VISOR_SSH_TARGET_PORT its
// port, 7433 unless said). The device's key must get in once it is
// authorized, a changed host key must be refused, a key not authorized
// must be refused, the client must sign in to the server through the
// forwarded port and see its sessions, and the same must hold through
// a jump host (the sshd itself, jumped through to itself).

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class SSHProbeTests: XCTestCase {
    func testReachesARealServerOverSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["VISOR_SSH_ADDRESS"], let authorized = environment["VISOR_SSH_AUTHORIZED_KEYS"] else {
            throw XCTSkip("VISOR_SSH_ADDRESS names an sshd whose authorized keys are VISOR_SSH_AUTHORIZED_KEYS")
        }
        let parsed = try XCTUnwrap(SSHAddress(address)).target
        let hop = VisorSSHHop(user: parsed.user, host: parsed.host, port: parsed.port)
        AgentServerConnection.cache = .inMemory()
        VisorHost.settings = MemorySettings()
        VisorHost.http = NativeVisorHTTPService()
        VisorHost.socket = NativeVisorSocketService()
        let ssh = NativeVisorSSHService()
        VisorHost.ssh = ssh
        defer { VisorHost.ssh = nil }

        // Not authorized yet: refused.
        do {
            _ = try await ssh.connect([hop], hostKeys: [nil])
            XCTFail("let in without the key")
        } catch VisorSSHError.keyRefused {}

        // Authorized: in, the host key seen, the port forwarded.
        let line = ssh.publicKey()
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 AAAA"), line)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: authorized))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        let session = try await ssh.connect([hop], hostKeys: [nil])
        XCTAssertEqual(session.hostKeys.count, 1)
        XCTAssertTrue(session.hostKeys[0].hasPrefix("ssh-"), session.hostKeys[0])
        let targetPort = Int(environment["VISOR_SSH_TARGET_PORT"] ?? "") ?? 7433
        let port = try await session.forward(toPort: targetPort)
        let answer = try await NativeVisorHTTPService().request(method: "GET", url: "http://127.0.0.1:\(port)/api/hello", body: "", authorization: environment["VISOR_SSH_PASSWORD"] ?? "")
        XCTAssertNotNil(Envelope.decode(answer)?.host, answer)
        session.close()

        // Someone else's host key: refused.
        do {
            _ = try await ssh.connect([hop], hostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
            XCTFail("let in with another host key")
        } catch VisorSSHError.hostKeyChanged {}

        // Through a jump host: the sshd, jumped through to itself.
        let jumped = try await ssh.connect([hop, hop], hostKeys: [session.hostKeys[0], nil])
        XCTAssertEqual(jumped.hostKeys, [session.hostKeys[0], session.hostKeys[0]])
        let jumpedPort = try await jumped.forward(toPort: targetPort)
        let jumpedAnswer = try await NativeVisorHTTPService().request(method: "GET", url: "http://127.0.0.1:\(jumpedPort)/api/hello", body: "", authorization: environment["VISOR_SSH_PASSWORD"] ?? "")
        XCTAssertNotNil(Envelope.decode(jumpedAnswer)?.host, jumpedAnswer)
        jumped.close()

        // The whole client, through the provider.
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: address, secret: environment["VISOR_SSH_PASSWORD"] ?? ""))
        host.connect()
        try await until("connected over SSH") { host.state == .connected }
        XCTAssertTrue(host.live, "the live channel goes through the tunnel")
        XCTAssertFalse(host.record.name.isEmpty)
        try await until("the sessions are listed") { !host.sessions.isEmpty }
        host.disconnect()
        print("VISOR_SSH ok: reached \(host.record.name) over SSH with \(host.sessions.count) sessions; the log:\n" + ConnectionLog.shared.text)
    }

    private func until(_ what: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("not within \(Int(seconds)) s: \(what)\n" + ConnectionLog.shared.text) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
