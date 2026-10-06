// What an agent has running in the background between turns — a command
// it put there, a monitor, an agent of its own — as Claude Code reports
// the whole list whenever it changes: kept on the session, sent with the
// list, gone when the list is empty or the process starts over.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class BackgroundWorkTests: ServerTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-background-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7981)
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func record(_ id: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    /// Claude Code's list, each task by its kind and words; an empty list
    /// is nothing in the background.
    func testClaudeSaysWhatRunsInTheBackground() {
        let changed = """
            {"type":"system","subtype":"background_tasks_changed","tasks":[\
            {"task_id":"bbp94fgoh","task_type":"local_bash","description":"Wait for CI on the ATS fix"},\
            {"task_id":"b1c43c1za","task_type":"monitor","description":"CI checks on visor PR #92"},\
            {"task_id":"af0e75e2","task_type":"local_agent","description":"Review the diff"}]}
            """
        XCTAssertEqual(ClaudeOutput.parse(changed), [.background([
            StatusItem(id: "bbp94fgoh", kind: .shell, label: "Wait for CI on the ATS fix", running: true),
            StatusItem(id: "b1c43c1za", kind: .monitor, label: "CI checks on visor PR #92", running: true),
            StatusItem(id: "af0e75e2", kind: .subagent, label: "Review the diff", running: true),
        ])])
        XCTAssertEqual(ClaudeOutput.parse(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#), [.background([])])
        // The notifications that follow say nothing the list does not.
        XCTAssertEqual(ClaudeOutput.parse(#"{"type":"system","subtype":"task_notification","task_id":"bbp94fgoh","status":"completed"}"#), [])
    }

    /// The session carries the list, through its JSON and its store,
    /// and loses it when its process is replaced.
    func testTheSessionCarriesItUntilTheProcessStartsOver() throws {
        let session = record("A")
        server.sessions = [session]
        let items = [StatusItem(id: "b1", kind: .monitor, label: "CI checks", running: true)]
        server.handle(.background(items), from: session)
        XCTAssertEqual(session.info.background, items)
        XCTAssertEqual(SessionInfo(json: session.info.json)?.background, items)
        let stored = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(session.info))
        XCTAssertEqual(stored.background, items)
        // A store from before the field reads as nothing in the background.
        let older = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"A"}"#.utf8))
        XCTAssertEqual(older.background, [])

        server.handle(.busy(false), from: session)
        XCTAssertEqual(session.info.background, items, "a turn ending does not end it")
        session.replaceProcess(ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        XCTAssertEqual(session.info.background, [])
    }
}
