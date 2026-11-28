// A session pinned to the top of its computer's list, or unpinned: the
// session's own, kept in its row of the sessions' store (server.sqlite),
// never in its JSON, and sent with it, so every client lists the same;
// kept through a restart. Archiving or ending takes the pin; an archived
// session isn't pinned. The pins an earlier build of 0.73 kept in
// messages.sqlite move into the store once.

import Foundation
import MessageCache
import SwiftSQL
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that does nothing.
@MainActor
private final class IdleAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, emit) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func startsTurn(_ text: String) -> Bool { true }
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

/// Makes idle agents, for a launch that reads the store again.
private final class IdleHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: []) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}
    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { IdleAgent() }
}

extension ServerTests {
@Suite @MainActor final class SessionPinsTests {
    private var server: VisorServer!

    private let root: URL

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-pins-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        // The server's database, a file of its own (as messages.sqlite is).
        ServerCache.shared = MessageCache.open(named: "messages", in: root)
        server = VisorServer(port: 7959)
        server.harnesses = AgentHarnesses([IdleHarness()])
    }

    isolated deinit {
        server.stop()
    }

    /// The sessions pinned in the store, as a second reader of it has them.
    private func pinnedRows() throws -> Set<String> {
        Set(try SessionStore(path: VisorServer.storeURL.path).rows().filter(\.pinned).map(\.id))
    }

    private func record(_ id: String, _ title: String? = nil) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title ?? id, created: 0), process: IdleAgent(), entries: [])
    }

    /// Pinned and unpinned, over the socket's envelopes; pinned again,
    /// nothing changes. Kept in the store's rows, never in their JSON.
    @Test func testAPinIsKeptInTheDatabase() throws {
        let (a, b) = (record("a"), record("b"))
        server.sessions = [a, b]
        #expect(!a.info.pinned && a.info.json["pinned"] == .null, "not pinned, and nothing said of it")
        server.perform(.pin(session: "b"), from: nil)
        server.perform(.pin(session: "a"), from: nil)
        server.perform(.pin(session: "a"), from: nil)
        #expect(a.info.pinned && b.info.pinned)
        #expect(try pinnedRows() == ["a", "b"])
        server.perform(.unpin(session: "b"), from: nil)
        #expect(!b.info.pinned)
        #expect(try pinnedRows() == ["a"])

        // The session's JSON says nothing of it.
        let stored = try JSONEncoder().encode(a.stored)
        #expect(!String(decoding: stored, as: UTF8.self).contains("\"pin"), "no pin in its JSON")
        #expect(try JSONDecoder().decode(StoredSession.self, from: stored).info.pinned == false)
    }

    /// Through a restart: the next launch reads the pins with the sessions.
    @Test func testPinsOutliveARestart() throws {
        server.sessions = [record("a", "Alpha"), record("b", "Beta")]
        server.perform(.pin(session: "b"), from: nil)

        // The app again: its sessions read back.
        let again = VisorServer(port: 7958)
        again.harnesses = AgentHarnesses([IdleHarness()])
        again.loadSessions()
        defer { again.stop() }
        #expect(again.session("b")?.info.pinned == true, "pinned still")
        #expect(again.session("a")?.info.pinned == false)
        #expect(SessionInfo(json: try #require(again.session("b")).info.json)?.pinned == true, "and told so")
    }

    /// The pin is the session's: in its info on the wire, set over REST.
    @Test func testThePinGoesOverTheWire() throws {
        server.password = "pw"
        let session = record("s")
        server.sessions = [session]
        // A session from before pins, or from an older server.
        let older = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"o","title":"Old"}"#.utf8))
        #expect(!older.pinned)
        #expect(SessionInfo(json: .object(["id": .string("o"), "agent": .string("claude"), "cwd": .string("/"), "title": .string("O")]))?.pinned == false)

        let answer = server.route(HTTPRequest(method: "POST", path: "/api/sessions/s/pin", headers: ["authorization": "Bearer pw"], body: "{}"))
        #expect(answer.status == 200)
        let reply = try #require(Envelope.decode(answer.body))
        #expect(reply.sessions?.first?.pinned == true, "the answer carries the session pinned")
        #expect(session.info.json["pinned"].bool == true)
        #expect(SessionInfo(json: session.info.json)?.pinned == true, "every client reads it")

        let unpinned = server.route(HTTPRequest(method: "POST", path: "/api/sessions/s/unpin", headers: ["authorization": "Bearer pw"], body: "{}"))
        #expect(unpinned.status == 200)
        #expect(!session.info.pinned)
        #expect(Envelope.decode(unpinned.body)?.sessions?.first?.pinned == false)
        #expect(try pinnedRows().isEmpty)

        // The socket's envelopes, as they go.
        #expect(Envelope.decode(Envelope.pin(session: "s").encoded())?.type == "pin")
        #expect(Envelope.decode(Envelope.unpin(session: "s").encoded())?.session == "s")
    }

    /// `hello` says the server keeps pins: what a client offers Pin by.
    @Test func testHelloSaysItKeepsPins() throws {
        server.password = "pw"
        let answer = server.route(HTTPRequest(method: "GET", path: "/api/hello", headers: ["authorization": "Bearer pw"], body: ""))
        #expect(answer.status == 200)
        #expect(Envelope.decode(answer.body)?.pins == true)
        #expect(Envelope.decode(#"{"type":"hello"}"#)?.pins == nil, "a server before pins says nothing")
    }

    /// Archiving takes the pin; an archived session isn't pinned. Ending
    /// one takes its pin from the database too.
    @Test func testAnArchivedOrEndedSessionIsNotPinned() throws {
        let session = record("s")
        server.sessions = [session, record("t")]
        server.perform(.pin(session: "s"), from: nil)
        #expect(session.info.pinned)
        server.perform(Envelope.archive(session: "s"), from: nil)
        #expect(session.info.archived)
        #expect(!session.info.pinned, "off the top of the list it has left")
        #expect(try pinnedRows().isEmpty)
        server.perform(.pin(session: "s"), from: nil)
        #expect(!session.info.pinned, "not while archived")
        server.perform(Envelope.unarchive(session: "s"), from: nil)
        #expect(!session.info.pinned, "back among the rest")

        server.perform(.pin(session: "t"), from: nil)
        server.perform(Envelope.end(session: "t"), from: nil)
        #expect(try pinnedRows().isEmpty, "gone with the session")
    }

    /// An earlier build of 0.73 kept its pins in messages.sqlite: they move
    /// into the store once, the archived and the gone passed over, and the
    /// cache's are never read again (an unpin holds through a restart).
    @Test func testPinsTheCacheKeptMoveInOnce() throws {
        let earlier = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-pins-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: earlier) }
        VisorServer.storeRoot = earlier
        let file = #"""
            [{"info":{"id":"a","agent":"claude","cwd":"/tmp","title":"Alpha","created":1},"entries":[]},
             {"info":{"id":"b","agent":"claude","cwd":"/tmp","title":"Beta","created":2},"entries":[]},
             {"info":{"id":"c","agent":"claude","cwd":"/tmp","title":"Gamma","created":3,"archived":true},"entries":[]}]
            """#
        try Data(file.utf8).write(to: earlier.appendingPathComponent("sessions.json"))
        let cache = earlier.appendingPathComponent("cache", isDirectory: true)
        _ = MessageCache.open(named: "messages", in: cache)
        try Database(path: cache.appendingPathComponent("messages.sqlite").path).execute(
            #"CREATE TABLE "pins" ("session" TEXT PRIMARY KEY NOT NULL); INSERT INTO pins VALUES ('b'), ('c'), ('gone')"#)
        ServerCache.shared = MessageCache.open(named: "messages", in: cache)
        defer { ServerCache.shared = .inMemory() }

        let first = VisorServer(port: 7957)
        defer { first.stop() }
        #expect(first.sessions.map(\.info.id) == ["a", "b", "c"])
        #expect(first.sessions.map(\.info.pinned) == [false, true, false], "an archived one isn't pinned")
        #expect(try pinnedRows() == ["b"])
        #expect(try SessionStore(path: VisorServer.storeURL.path).note(VisorServer.pinsMovedNote) != nil)

        // Unpinned here: the cache still has it, and isn't read again.
        first.perform(.unpin(session: "b"), from: nil)
        first.perform(.pin(session: "a"), from: nil)
        let second = VisorServer(port: 7956)
        defer { second.stop() }
        #expect(second.sessions.map(\.info.pinned) == [true, false, false])
        #expect(ServerCache.shared.pinnedSessions() == ["b", "c", "gone"], "the cache's table left as it was")
        let third = VisorServer(port: 7955)
        defer { third.stop() }
        #expect(third.sessions.map(\.info.pinned) == [true, false, false])
    }

    /// A cache that couldn't be opened (in memory in its file's place) has
    /// no pins to give, which isn't the same as none: nothing is noted as
    /// moved, and the next start, with the cache's file, moves them.
    @Test func testPinsAreNotMarkedMovedWhenTheCacheWasntRead() throws {
        let earlier = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-pins-unread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: earlier) }
        VisorServer.storeRoot = earlier
        try Data(#"[{"info":{"id":"a","agent":"claude","cwd":"/tmp","title":"Alpha","created":1},"entries":[]}]"#.utf8)
            .write(to: earlier.appendingPathComponent("sessions.json"))
        ServerCache.shared = .inMemory()
        defer { ServerCache.shared = .inMemory() }
        let first = VisorServer(port: 7954)
        defer { first.stop() }
        #expect(first.sessions.map(\.info.pinned) == [false])
        #expect(try SessionStore(path: VisorServer.storeURL.path).note(VisorServer.pinsMovedNote) == nil, "not noted")

        let cache = earlier.appendingPathComponent("cache", isDirectory: true)
        _ = MessageCache.open(named: "messages", in: cache)
        try Database(path: cache.appendingPathComponent("messages.sqlite").path).execute(
            #"CREATE TABLE "pins" ("session" TEXT PRIMARY KEY NOT NULL); INSERT INTO pins VALUES ('a')"#)
        ServerCache.shared = MessageCache.open(named: "messages", in: cache)
        let second = VisorServer(port: 7953)
        defer { second.stop() }
        #expect(second.sessions.map(\.info.pinned) == [true], "moved once the cache was read")
        #expect(try SessionStore(path: VisorServer.storeURL.path).note(VisorServer.pinsMovedNote) != nil)
    }

    /// A pinned session comes through an older build's sessions.json, imported
    /// again, still pinned: the merge keeps its pin.
    @Test func testAPinSurvivesAReimport() throws {
        let earlier = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-pins-reimport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: earlier) }
        VisorServer.storeRoot = earlier
        let json = earlier.appendingPathComponent("sessions.json")
        try Data(#"[{"info":{"id":"a","agent":"claude","cwd":"/tmp","title":"Alpha","created":1},"entries":[]}]"#.utf8).write(to: json)
        let first = VisorServer(port: 7952)
        defer { first.stop() }
        first.perform(.pin(session: "a"), from: nil)
        // The older build's file: the same session, written again.
        try Data(#"[{"info":{"id":"a","agent":"claude","cwd":"/tmp","title":"Alpha, from 0.72","created":1},"entries":[]}]"#.utf8)
            .write(to: json, options: .atomic)
        let second = VisorServer(port: 7951)
        defer { second.stop() }
        #expect((second.session("a")?.info.title) == "Alpha, from 0.72", "imported again")
        #expect((second.session("a")?.info.pinned) == true, "still pinned")
        #expect(try pinnedRows() == ["a"])
    }
}
}
