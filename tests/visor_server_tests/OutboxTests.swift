// The outbox: what is said while the agent works waits on the server with
// the files it came with, and is written down with the session, so neither
// a busy agent nor a restart of the app loses a message or its attachments.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class OutboxTests: XCTestCase {
    private func record() -> SessionRecord {
        let info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "t", created: 0)
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
    }

    func testQueuedMessagesKeepTheirFiles() {
        let r = record()
        r.enqueue("Look at this", images: ["/files/a.png"])
        r.enqueue("", images: ["/files/clip.mov"])
        r.enqueue("And this", images: [])
        // Clients see the words.
        XCTAssertEqual(r.info.queued, ["Look at this", "", "And this"])

        // Dropping one drops its files.
        r.unqueue("And this")
        XCTAssertEqual(r.queuedImages, [["/files/a.png"], ["/files/clip.mov"]])

        // Taken as one message: the words in order, every file.
        let waiting = r.takeQueue()
        XCTAssertEqual(waiting.text, "Look at this")
        XCTAssertEqual(waiting.images, ["/files/a.png", "/files/clip.mov"])
        XCTAssertTrue(r.info.queued.isEmpty)
        XCTAssertTrue(r.queuedImages.isEmpty)
    }

    func testTheOutboxIsWrittenDownWithTheSession() throws {
        let r = record()
        r.enqueue("Look at this", images: ["/files/a.png"])
        let data = try JSONEncoder().encode(r.stored)
        let back = try JSONDecoder().decode(StoredSession.self, from: data)
        XCTAssertEqual(back.info.queued, ["Look at this"])
        XCTAssertEqual(back.queuedImages, [["/files/a.png"]])

        // A file from before the outbox was kept reads as words alone.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "queuedImages")
        let older = try JSONDecoder().decode(StoredSession.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(older.queuedImages)
        XCTAssertEqual(older.info.queued, ["Look at this"])
    }
}
