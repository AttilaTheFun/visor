// The outbox: what is said while the agent works waits on the server with
// the files it came with, and is written down with the session, so neither
// a busy agent nor a restart of the app loses a message or its attachments.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class OutboxTests: ServerTestCase {
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

        // Taken a message at a time, each with its own files.
        let first = r.takeNextQueued()
        XCTAssertEqual(first?.text, "Look at this")
        XCTAssertEqual(first?.images, ["/files/a.png"])
        let second = r.takeNextQueued()
        XCTAssertEqual(second?.text, "")
        XCTAssertEqual(second?.images, ["/files/clip.mov"])
        XCTAssertNil(r.takeNextQueued())
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

    /// A message handed over from the queue is in neither the queue nor the
    /// thread until the agent's log has it (Codex compacting its context
    /// first, for minutes): the session says it was delivered meanwhile,
    /// while the agent works, never an agent's own command.
    func testWhatTheAgentHasNotWrittenDownIsSaidDelivered() {
        let r = record()
        _ = r.apply(.busy(true))
        r.appendUser("remove the label")
        r.appendUser("/goal ship it")
        XCTAssertEqual(r.info.delivered, ["remove the label"])
        // Written to the log: no longer on its way.
        _ = r.take(fileRow: TranscriptEntry(id: "user-file-1", role: .user, text: "remove the label"))
        XCTAssertEqual(r.info.delivered, [])
        // The turn over: nothing is on its way, whatever was not written.
        r.appendUser("and the case")
        XCTAssertEqual(r.info.delivered, ["and the case"])
        _ = r.apply(.busy(false))
        XCTAssertEqual(r.info.delivered, [])
        // Neither kept on disk nor read back from it.
        _ = r.apply(.busy(true))
        XCTAssertEqual(r.info.delivered, ["and the case"])
        let reloaded = SessionRecord(info: r.info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))
        XCTAssertEqual(reloaded.info.delivered, [])
    }

    /// Words handed to an agent that went before its log had them (it
    /// exited as it started) were never taken: not said delivered under a
    /// later turn, and let go of once the log has had its time.
    func testWhatAGoneAgentNeverWroteIsNotSaidDeliveredAgain() {
        let r = record()
        _ = r.apply(.busy(true))
        r.appendUser("what is the current status?")
        XCTAssertTrue(r.agentWent())
        XCTAssertEqual(r.info.delivered, [], "no longer on its way")
        XCTAssertFalse(r.agentWent(), "nothing more went")
        _ = r.apply(.busy(false))
        // The next agent's turn shows only what it was handed.
        _ = r.apply(.busy(true))
        r.appendUser("hello")
        XCTAssertEqual(r.info.delivered, ["hello"])
        XCTAssertEqual(r.dropUntaken(after: .seconds(60)), [], "the log has its time first")
        XCTAssertEqual(r.dropUntaken(after: .zero), ["what is the current status?"])
        XCTAssertEqual(r.info.delivered, ["hello"])
    }

    /// Written by the log after its agent went (the log a moment behind):
    /// taken after all, so nothing is said of it.
    func testWhatTheLogWritesLateWasTaken() {
        let r = record()
        _ = r.apply(.busy(true))
        r.appendUser("remove the label")
        r.agentWent()
        _ = r.take(fileRow: TranscriptEntry(id: "user-file-1", role: .user, text: "remove the label"))
        XCTAssertEqual(r.dropUntaken(after: .zero), [])
    }

    /// The server, told the agent went (its memory gone), names what it
    /// never took once the log has had its time, for the user to say again;
    /// a command its log may never write is let go of quietly.
    func testTheSessionSaysWhatTheAgentNeverTook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-outbox-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let grace = VisorServer.untakenGrace
        VisorServer.untakenGrace = .milliseconds(50)
        defer { VisorServer.untakenGrace = grace }
        let server = VisorServer(port: 7972)
        defer { server.stop() }
        let r = record()
        server.sessions = [r]
        _ = r.apply(.busy(true))
        r.appendUser("what is the current status?")
        r.appendUser("/goal ship it")
        server.handle(.memory(nil), from: r)
        server.handle(.busy(false), from: r)
        for _ in 0..<40 where r.notice == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(r.notice, "The agent ended before it took “what is the current status?”: say it again.")
        XCTAssertTrue(r.unwritten.isEmpty)
    }
}
