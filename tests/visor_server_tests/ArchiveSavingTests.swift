// The sessions' store, written whole: once a while after a change, with
// every change made by then, not once per change (it was most of the
// gigabytes a day the Mac saw Visor write); at once where it must be (a
// session made or ended, before a quit); and its copy of the day before
// made once a day, not on every write.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import XCTest

/// An agent that does nothing: the store is what is under test.
@MainActor
private final class IdleAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

@MainActor
final class ArchiveSavingTests: ServerTestCase {
    private var server: VisorServer!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-archive-saving-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7991)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ id: String, title: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0), process: IdleAgent())
    }

    private var stored: String { (try? String(contentsOf: VisorServer.storeURL, encoding: .utf8)) ?? "" }

    func testChangesAreWrittenOnceTheirDelayIsOverAllTogether() async throws {
        server.archiveSaveDelay = .milliseconds(200)
        let first = record("S", title: "First")
        server.sessions = [first]
        server.saveArchiveNow()
        XCTAssertTrue(stored.contains("First"))

        first.info.title = "Second"
        server.saveArchive()
        first.info.title = "Third"
        server.saveArchive()
        XCTAssertFalse(stored.contains("Third"), "not yet: it waits for the changes after it")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(stored.contains("Third"), "then written once, with the last of them")
        XCTAssertFalse(server.archiveSavePending)
    }

    func testWrittenAtOnceWhenItMustBeAndAWaitingWriteIsTakenWithIt() async throws {
        server.archiveSaveDelay = .seconds(60)
        let first = record("S", title: "Waiting")
        server.sessions = [first]
        server.saveArchive()
        XCTAssertFalse(stored.contains("Waiting"))
        server.saveArchiveNow()
        XCTAssertTrue(stored.contains("Waiting"))
        XCTAssertFalse(server.archiveSavePending, "nothing left waiting")
    }

    func testTheCopyOfTheDayBeforeIsMadeOnceADay() throws {
        let backup = root.appendingPathComponent("sessions.previous.json")
        XCTAssertTrue(VisorServer.backupIsDue(backup), "none yet")
        try Data("[]".utf8).write(to: backup)
        XCTAssertFalse(VisorServer.backupIsDue(backup), "just made")
        XCTAssertTrue(VisorServer.backupIsDue(backup, now: Date().addingTimeInterval(25 * 60 * 60)), "a day on")

        // Writes in a row: the copy is made by the first, and kept.
        let session = record("S", title: "One")
        server.sessions = [session]
        server.saveArchiveNow()
        try? FileManager.default.removeItem(at: backup)
        session.info.title = "Two"
        server.saveArchiveNow()
        let copied = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(copied.contains("One"))
        session.info.title = "Three"
        server.saveArchiveNow()
        XCTAssertTrue(try String(contentsOf: backup, encoding: .utf8).contains("One"), "not rewritten on the next write")
        XCTAssertTrue(stored.contains("Three"))
    }
}
