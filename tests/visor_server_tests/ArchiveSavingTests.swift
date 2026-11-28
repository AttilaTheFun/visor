// The sessions' store, written once a while after a change, with every
// change made by then, not once per change (written whole, as sessions.json,
// it was most of the gigabytes a day the Mac saw Visor write); at once where
// it must be (a session made or ended, before a quit); and only the
// sessions that changed, never the whole store.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

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

extension ServerTests {
@Suite @MainActor final class ArchiveSavingTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-archive-saving-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7991)
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ id: String, title: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0), process: IdleAgent())
    }

    /// The store's rows as a second reader of the file has them.
    private var stored: String { ((try? SessionStore(path: VisorServer.storeURL.path).rows()) ?? []).map(\.stored).joined(separator: "\n") }

    @Test func testChangesAreWrittenOnceTheirDelayIsOverAllTogether() async throws {
        server.archiveSaveDelay = .milliseconds(200)
        let first = record("S", title: "First")
        server.sessions = [first]
        server.saveArchiveNow()
        #expect(stored.contains("First"))

        first.info.title = "Second"
        server.saveArchive()
        first.info.title = "Third"
        server.saveArchive()
        #expect(!stored.contains("Third"), "not yet: it waits for the changes after it")
        try await Task.sleep(for: .milliseconds(600))
        #expect(stored.contains("Third"), "then written once, with the last of them")
        #expect(!server.archiveSavePending)
    }

    @Test func testWrittenAtOnceWhenItMustBeAndAWaitingWriteIsTakenWithIt() async throws {
        server.archiveSaveDelay = .seconds(60)
        let first = record("S", title: "Waiting")
        server.sessions = [first]
        server.saveArchive()
        #expect(!stored.contains("Waiting"))
        server.saveArchiveNow()
        #expect(stored.contains("Waiting"))
        #expect(!server.archiveSavePending, "nothing left waiting")
    }

    @Test func testOnlyTheSessionsThatChangedAreWritten() throws {
        let one = record("A", title: "One")
        let other = record("B", title: "Other")
        server.sessions = [one, other]
        server.saveArchiveNow()

        // B's row, changed behind the server's back: a write that isn't
        // B's leaves it as it is.
        let reader = try SessionStore(path: VisorServer.storeURL.path)
        var marked = try #require(try reader.rows().first(where: { $0.id == "B" }))
        marked.title = "Marked"
        try reader.write(put: [marked])
        one.info.title = "Two"
        server.saveArchiveNow()
        let rows = try reader.rows()
        #expect(rows.map(\.title) == ["Two", "Marked"], "A written, B not")

        // Nothing changed: nothing written.
        try reader.write(put: [marked, SessionStore.Row(id: "A", position: 0, title: "Kept", archived: false, stored: rows[0].stored)])
        server.saveArchiveNow()
        #expect(try reader.rows().map(\.title) == ["Kept", "Marked"])

        // B gone: its row deleted, and A's place is as it was.
        server.sessions = [one]
        server.saveArchiveNow()
        #expect(try reader.rows().map(\.id) == ["A"])

        // In front of A, a new one: A moves, without being written again.
        server.sessions = [record("C", title: "New"), one]
        server.saveArchiveNow()
        #expect(try reader.rows().map(\.id) == ["C", "A"])
        #expect(try reader.rows().map(\.title) == ["New", "Kept"])
    }
}
}
