// What the user sends to Claude is no row until Claude's log writes it:
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
        XCTAssertNil(r.appendUser("go on"))
        XCTAssertEqual(r.entries.map(\.id), ["user-file-a", "msg_1"])
        XCTAssertEqual(r.unwritten.count, 1)

        // The log still has only the first "go on": this one waits.
        r.settle(in: [first, reply])
        XCTAssertEqual(r.unwritten.count, 1)

        // The log writes it: remembered no more.
        r.settle(in: [first, reply, TranscriptEntry(id: "user-file-b", role: .user, text: "go on")])
        XCTAssertTrue(r.unwritten.isEmpty)
    }

    func testOtherAgentsKeepTheirOwnRow() {
        let info = SessionInfo(id: "c", agent: .codex, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: CodexAppServerProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        XCTAssertNotNil(r.appendUser("Build it"))
        XCTAssertEqual(r.entries.map(\.text), ["Build it"])
    }
}
