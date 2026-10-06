// The polling fallback against a real server, over the native services:
// run by hand with VISOR_POLL_URL set to a Visor server's address behind
// a front that carries no WebSockets (tools/probes/noweb_proxy.mjs in
// front of a staging server), and VISOR_POLL_PASSWORD its password. The
// client must come up by polling, see the sessions, start a throwaway
// session, follow its state, and end it.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class PollingProbeTests: XCTestCase {
    func testFollowsARealServerByPolling() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["VISOR_POLL_URL"] else { throw XCTSkip("VISOR_POLL_URL names a server behind a front with no WebSockets") }
        AgentServerConnection.cache = .inMemory()
        VisorHost.settings = MemorySettings()
        VisorHost.http = NativeVisorHTTPService()
        VisorHost.socket = NativeVisorSocketService()
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: url, secret: environment["VISOR_POLL_PASSWORD"] ?? ""))
        host.connect()
        try await until("connected by polling") { host.state == .connected && !host.live }
        XCTAssertFalse(host.record.name.isEmpty)

        let id = host.start(agent: .claude, cwd: "/tmp/visor-probe", title: "probe-polling", skipPermissions: true)
        try await until("the session is listed") { host.sessions.contains { $0.id == id } }
        host.sendMessage(id, text: "Reply with exactly the word ONE.")
        try await until("the session is seen working", seconds: 30) { host.transcripts[id]?.busy == true }
        try await until("the reply is on the record", seconds: 90) {
            host.transcripts[id]?.busy == false && (host.transcripts[id]?.entries.contains { $0.role == .assistant && $0.text.contains("ONE") } ?? false)
        }
        host.end(id)
        try await until("the session is gone") { !host.sessions.contains { $0.id == id } }
        print("VISOR_POLL ok: followed \(host.record.name) by polling; the log:\n" + ConnectionLog.shared.text)
    }

    private func until(_ what: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("not within \(Int(seconds)) s: \(what)\n" + ConnectionLog.shared.text) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
