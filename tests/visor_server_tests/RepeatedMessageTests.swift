// The same words sent again are a new message: the file holding the
// earlier one does not make the new one written.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class RepeatedMessageTests: XCTestCase {
    func testAMessageSentAgainStaysUntilWritten() {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        let r = SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        let first = TranscriptEntry(id: "user-file-a", role: .user, text: "go on")
        let reply = TranscriptEntry(id: "msg_1", role: .assistant, text: "Done.")
        let again = TranscriptEntry(id: "user-3-x", role: .user, text: "go on")
        // The file has only the first: the second is still on its way.
        XCTAssertEqual(r.merged(fileRows: [first, reply], into: [first, reply, again]).map(\.id), ["user-file-a", "msg_1", "user-3-x"])
        // The file has both: the second is written, once, and keeps the id
        // it was shown under.
        let written = TranscriptEntry(id: "user-file-b", role: .user, text: "go on")
        XCTAssertEqual(r.merged(fileRows: [first, reply, written], into: [first, reply, again]).map(\.id), ["user-file-a", "msg_1", "user-3-x"])
    }
}
