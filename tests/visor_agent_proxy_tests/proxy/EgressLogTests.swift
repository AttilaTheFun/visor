// The egress log: each connection a line, read back oldest first, the file
// before kept once the limit is passed, and summed by caller and host.
// Moved from MultiPass's host log tests (Logan, 2026-11-14).

import Foundation
@testable import VisorAgentProxy
import XCTest

final class EgressLogTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("egress-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + seconds) }

    func testEntriesAreReadBackOldestFirstAndTheFileBeforeIsKept() throws {
        let log = EgressLog(file: folder.appendingPathComponent("Shireworks-egress.log"), limit: 600)
        let entries = (0..<8).map {
            EgressLog.Entry(time: at(Double($0)), host: "example.com", port: 443, lease: "lease-\($0 % 2)", route: .egress, outcome: .tunnelled)
        }
        for entry in entries { log.record(entry) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.previous.path), "past the limit: the file before kept")
        XCTAssertEqual(log.previous.lastPathComponent, "Shireworks-egress.1.log")
        let read = log.entries()
        XCTAssertFalse(read.isEmpty)
        XCTAssertEqual(read, Array(entries.suffix(read.count)), "the newest kept, in order")
        let permissions = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testALineIsItsConnectionAsJSON() throws {
        let log = EgressLog(file: folder.appendingPathComponent("logs/egress.log"))
        log.record(EgressLog.Entry(time: at(0), host: "visor.agent.internal", port: 7434, lease: "lease-42",
                                   agentClaimed: "0b5e7a52-1c1b-4e2a-9c3d-5f6a7b8c9d0e", route: .dialIn, outcome: .tunnelled))
        let text = try String(contentsOf: log.file, encoding: .utf8)
        XCTAssertEqual(text, #"{"agentClaimed":"0b5e7a52-1c1b-4e2a-9c3d-5f6a7b8c9d0e","host":"visor.agent.internal","lease":"lease-42","#
            + #""outcome":"tunnelled","port":7434,"route":"dial-in","time":"2026-11-06T21:20:00Z"}"# + "\n",
                       "its folder made, a line of JSON")
    }

    func testSummariesAreByCallerAndHost() {
        let summaries = EgressLog.summaries([
            EgressLog.Entry(time: at(0), host: "github.com", port: 443, lease: "b", route: .github, outcome: .opened),
            EgressLog.Entry(time: at(5), host: "example.com", port: 443, lease: "a", route: .egress, outcome: .tunnelled),
            EgressLog.Entry(time: at(9), host: "example.com", port: 443, lease: "a", route: .egress, outcome: .unreachable),
            EgressLog.Entry(time: at(7), host: "example.com", port: 80, lease: "a", route: .egress, outcome: .forwarded),
        ])
        XCTAssertEqual(summaries.map { "\($0.caller) \($0.host):\($0.port) \($0.count)" },
                       ["container:a example.com:80 1", "container:a example.com:443 2", "container:b github.com:443 1"])
        XCTAssertEqual(summaries[1].outcomes, [.tunnelled, .unreachable])
        XCTAssertEqual(summaries[1].last, at(9))
    }
}
