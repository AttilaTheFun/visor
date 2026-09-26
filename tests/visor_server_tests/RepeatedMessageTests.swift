// What the user sends is no row until the agent's log writes it:
// the server remembers the words as sent, and the same words sent again
// are a new message, not the one already written.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class RepeatedMessageTests: XCTestCase {
    func testSentWordsWaitForTheLog() {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        let first = TranscriptEntry(id: "user-file-a", role: .user, text: "go on")
        let reply = TranscriptEntry(id: "msg_1", role: .assistant, text: "Done.")
        r.replaceEntriesForTesting([first, reply])

        // Sent: no row, remembered.
        r.appendUser("go on")
        XCTAssertEqual(r.entries.map(\.id), ["user-file-a", "msg_1"])
        XCTAssertEqual(r.unwritten.count, 1)

        // The log still has only the first "go on": this one waits.
        r.settle(in: [first, reply])
        XCTAssertEqual(r.unwritten.count, 1)

        // The log writes it: remembered no more.
        r.settle(in: [first, reply, TranscriptEntry(id: "user-file-b", role: .user, text: "go on")])
        XCTAssertTrue(r.unwritten.isEmpty)
    }

    func testEveryAgentWaitsForItsLog() {
        let info = SessionInfo(id: "c", agent: .codex, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        r.appendUser("Build it")
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertEqual(r.unwritten.map(\.text), ["Build it"])
        // A row the process reports is not the record: the log is.
        XCTAssertNil(r.apply(.entry(TranscriptEntry(id: "x", role: .assistant, text: "Built."))))
        XCTAssertTrue(r.entries.isEmpty)
    }
}
