// The sessions' store in the server's database (server.sqlite): sessions.json
// imported into it once, everything in it kept, in its order, and the
// files renamed, never deleted, with a read-only copy left for an older
// build; a file that can't be read left as it is; each session written on
// its own, through a restart, an archive and an end; writes at once from
// many places; and a file from a later build left alone.

import Foundation
import SwiftSQL
import Synchronization
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that does nothing: the store is what is under test.
@MainActor
private final class StillAgent: AgentProcess {
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

/// What the server logged.
private final class LoggedLines: Sendable {
    private let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

extension ServerTests {
@Suite @MainActor final class SessionStoreTests {
    private var root: URL!
    private var servers: [VisorServer] = []
    private let logged = LoggedLines()

    init() async throws {
        TestPlatform.install()
        var platform = ServerPlatform.current
        let logged = logged
        platform.log = { logged.add($0) }
        ServerPlatform.current = platform
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
    }

    isolated deinit {
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    /// A server started over the data folder, as a launch makes one.
    private func launch() -> VisorServer {
        let server = VisorServer(port: 7996)
        servers.append(server)
        return server
    }

    private func record(_ id: String, title: String) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0), process: StillAgent())
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    private var day: String { RetiredFiles.day(Date()) }

    /// A second reader of the server's database.
    private func reader() throws -> SessionStore { try SessionStore(path: VisorServer.storeURL.path) }

    // MARK: A sessions.json as the Mini's has it

    /// Two sessions with what a live one and an archived one keep (the
    /// Mini's keys, 26 Nov 2026; the values made up), the archived first:
    /// the file's order is the list's, not the ids'. With `elsewhere`, a
    /// third, moved to a runner and left under its host mid-turn, with a
    /// fork pending: what a load would act on, so only imported.
    private static func sessionsJSON(elsewhere: Bool = false) -> String {
        let beta = #"""
            {"info":{"id":"beta","agent":"codex","cwd":"/tmp/beta","title":"Beta","busy":false,"ended":false,"skipPermissions":true,
              "archived":true,"created":1763800000.5,"queued":[],"delivered":[],"background":[],"side":[],"subagents":[],"mcp":[],
              "unreadMail":0,"notifications":true,"agentState":"stopped","resumeCommand":"codex resume conv-b"},
             "entries":[],"resumeID":"conv-b","shape":2}
            """#
        let alpha = #"""
            {"info":{"id":"alpha","agent":"claude","cwd":"/tmp/alpha","title":"Alpha","busy":true,"ended":false,"skipPermissions":false,
              "archived":false,"resumeCommand":"cd /tmp/alpha && claude --resume conv-a","model":"opus","reportedModel":"claude-opus-4",
              "effort":"high","contextUsed":1200,"contextLimit":200000,"usage":{"input":120,"cached":80,"output":40,"cost":0.25},
              "queued":["Then this"],"delivered":["Sent"],"created":1763900000.5,"preview":"Hello there","updated":1763900100.25,
              "goal":"Ship it","background":[],"turn":{"phase":"thinking"},"memory":1048576,"agentState":"running","system":"linux",
              "side":[{"id":"q1","question":"Why?","answer":"Because.","asked":1763900050.5}],
              "subagents":[{"id":"a1","description":"Look around","type":"Explore","running":true}],
              "mcp":[{"name":"gh","on":false}],"unreadMail":1,"mailChanged":1763900090.75,"notifications":false,"turnOrigin":"mail",
              "placement":"host","continuedFrom":"older"},
             "entries":[{"id":"u1","role":"user","text":"Hello","activities":[],"images":[],"imageSizes":[]},
                        {"id":"r1","role":"assistant","text":"Hello there","activities":["Read a file"],"toolName":"Read","images":[],"imageSizes":[]}],
             "resumeID":"conv-a","shape":2,"interrupted":false,"shownPrompts":["p1"],"notice":"Read this","queuedImages":[[]],
             "queuedOrigins":["user"],"reportedUsage":{"input":100,"cached":50,"output":20,"cost":0.125},"head":"p1","leaf":"r1-uuid",
             "otherBranch":"p9","branchKept":true,"watchedSubagents":["a1"],"closedSubagents":["a0"],"mcpSwitched":{"gh":false},
             "mailbox":{"inbox":[{"id":"m1","from":{"server":"s1","serverName":"Mini","session":"other","sessionName":"Other"},
                                  "to":{"server":"s1","serverName":"Mini","session":"alpha","sessionName":"Alpha"},
                                  "text":"Hi","sent":1763900080.5,"state":"delivered","changed":1763900080.5}],"outbox":[]}}
            """#
        let gamma = #"""
            {"info":{"id":"gamma","agent":"claude","cwd":"/tmp/gamma","title":"Gamma","busy":true,"ended":false,"skipPermissions":true,
              "archived":false,"created":1763900200.5,"queued":[],"delivered":[],"background":[],"side":[],"subagents":[],"mcp":[],
              "unreadMail":0,"notifications":true,"placement":"runner"},
             "entries":[],"resumeID":"conv-g","shape":2,"interrupted":true,"agentPID":2147480000,
             "host":{"socket":"/tmp/gamma.sock","line":42,"carried":{"turn":"t1"},"ownToken":true,"jwt":true},
             "fork":{"from":"alpha","at":"r1"},"driven":true,
             "move":{"agent":"runner-agent","session":"gamma","title":"Gamma","model":"opus","effort":"high","resume":"conv-g","cwd":"/tmp/gamma",
                     "sources":[{"repository":"https://github.com/example/gamma.git","ref":"main","name":"gamma"}],"runsOn":"runner-1",
                     "workingDirectory":"/work/gamma","conversation":"conv-g2","skipPermissions":true}}
            """#
        return "[" + ([beta, alpha] + (elsewhere ? [gamma] : [])).joined(separator: ",\n") + "]"
    }

    /// Whether everything `expected` has is in `actual`, as JSON: each key
    /// of an object (but `skipping`), each element of an array, each value.
    private func holds(_ actual: Any?, _ expected: Any, skipping: Set<String> = []) -> Bool {
        switch expected {
        case let object as [String: Any]:
            guard let actual = actual as? [String: Any] else { return false }
            return object.allSatisfy { skipping.contains($0.key) || holds(actual[$0.key], $0.value, skipping: skipping) }
        case let array as [Any]:
            guard let actual = actual as? [Any], actual.count == array.count else { return false }
            return zip(actual, array).allSatisfy { holds($0, $1, skipping: skipping) }
        default:
            return actual.map { "\($0)" } == "\(expected)"
        }
    }

    @Test func testEveryFieldOfARealShapedFileIsImported() throws {
        // A server over an empty data folder, then the file imported into
        // a store apart from it: nothing of the sessions is acted on.
        let server = launch()
        let text = Self.sessionsJSON(elsewhere: true)
        try Data(text.utf8).write(to: file("sessions.json"))
        let store = try SessionStore(path: ":memory:")
        #expect(server.importLegacyStore(into: store))
        let rows = try store.rows()
        #expect(rows.map(\.id) == ["beta", "alpha", "gamma"])
        #expect(rows.map(\.position) == [0, 1, 2])
        #expect(rows.map(\.title) == ["Beta", "Alpha", "Gamma"])
        #expect(rows.map(\.archived) == [true, false, false])
        #expect(rows.map(\.updated) == [nil, 1763900100.25, nil])
        #expect(rows.allSatisfy { !$0.pinned }, "sessions.json kept no pins")

        let original = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        for (row, kept) in zip(rows, original) {
            let stored = try JSONSerialization.jsonObject(with: Data(row.stored.utf8))
            // All of it, but the turn: never read back (SessionInfo.turn).
            #expect(holds(stored, kept, skipping: ["turn"]), "\(row.id) as it was")
            // And as a later save writes it: the same text.
            let session = try JSONDecoder().decode(StoredSession.self, from: Data(row.stored.utf8))
            #expect(try SessionStore.Row.encoded(session) == row.stored)
        }
        let gamma = try JSONDecoder().decode(StoredSession.self, from: Data(rows[2].stored.utf8))
        #expect(gamma.host == StoredHost(socket: "/tmp/gamma.sock", line: 42, carried: ["turn": "t1"], ownToken: true, jwt: true))
        #expect(gamma.move?.conversation == "conv-g2")
        #expect(gamma.fork == PendingFork(from: "alpha", at: "r1"))
        #expect(gamma.agentPID == 2147480000)
        #expect(gamma.driven == true)
    }

    @Test func testAnUpgradeBringsBackTheSameSessionsInTheSameOrder() throws {
        let text = Self.sessionsJSON()
        try Data(text.utf8).write(to: file("sessions.json"))
        try Data("[]".utf8).write(to: file("sessions.previous.json"))
        let server = launch()
        #expect(server.storeIsReadable)
        #expect(server.sessions.map(\.info.id) == ["beta", "alpha"])
        let alpha = try #require(server.session("alpha"))
        #expect(alpha.info.title == "Alpha")
        #expect(alpha.info.model == "opus")
        #expect(alpha.info.effort == "high")
        #expect(!alpha.info.notifications)
        #expect(alpha.info.placement == .host)
        #expect(alpha.info.continuedFrom == "older")
        #expect(alpha.info.queued == ["Then this"])
        #expect(alpha.info.agentState == .running)
        #expect(!alpha.info.busy, "back idle, as from sessions.json")
        #expect(alpha.mailbox.inbox.map(\.id) == ["m1"])
        #expect(alpha.notice == "Read this")
        #expect(alpha.head == "p1")
        #expect(alpha.closedSubagents == ["a0"])
        #expect(alpha.mcpSwitched == ["gh": false])
        let beta = try #require(server.session("beta"))
        #expect(beta.info.archived)
        #expect(beta.info.agentState == .stopped)
        #expect(beta.info.agent == .codex)

        // sessions.json left where an older build reads it, read-only and
        // never missing, with a copy beside it; the other renamed. Nothing
        // deleted.
        #expect(try String(contentsOf: file("sessions.json.imported-\(day)"), encoding: .utf8) == text)
        #expect(try String(contentsOf: file("sessions.previous.json.imported-\(day)"), encoding: .utf8) == "[]")
        #expect(!FileManager.default.fileExists(atPath: file("sessions.previous.json").path))
        #expect(try String(contentsOf: file("sessions.json"), encoding: .utf8) == text)
        let mode = (try FileManager.default.attributesOfItem(atPath: file("sessions.json").path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o444)
        #expect(logged.all.contains { $0.contains("imported 2 sessions from sessions.json") })

        // What the first launch wrote is what the database gives back, and
        // the next launch reads it.
        let first = try server.sessions.map { try SessionStore.Row.encoded($0.stored) }
        #expect(try reader().rows().map(\.stored) == first)
        let again = launch()
        #expect(again.sessions.map(\.info.id) == ["beta", "alpha"])
        #expect((again.session("alpha")?.info.title) == "Alpha")
        #expect((again.session("alpha")?.mailbox.inbox.map(\.id)) == ["m1"])
        #expect((again.session("beta")?.info.archived) == true)
    }

    @Test func testTheImportRunsOnceAndAgainOnlyForAnOlderBuildsFile() throws {
        try Data(Self.sessionsJSON().utf8).write(to: file("sessions.json"))
        let first = launch()
        let alpha = try #require(first.session("alpha"))
        alpha.info.title = "Renamed since"
        first.saveArchiveNow()
        let ended = try #require(first.session("beta"))
        first.sessions.removeAll { $0 === ended }
        first.saveArchiveNow()

        // The copy left is the file imported: not imported again, and
        // nothing more renamed.
        let second = launch()
        #expect(second.sessions.map(\.info.title) == ["Renamed since"])
        let third = launch()
        #expect(third.sessions.map(\.info.title) == ["Renamed since"])
        #expect(!FileManager.default.fileExists(atPath: file("sessions.json.imported-\(day)-2").path))
        #expect(logged.all.filter { $0.contains("from sessions.json into") }.count == 1)

        // A build of 0.72 or before ran since, and wrote its own: merged in,
        // what the store has that the file hasn't kept.
        let older = #"[{"info":{"id":"older","agent":"claude","cwd":"/tmp","title":"From 0.72","created":3},"entries":[]}]"#
        try Data(older.utf8).write(to: file("sessions.json"), options: .atomic)
        let fourth = launch()
        #expect(fourth.sessions.map(\.info.id) == ["alpha", "older"])
        #expect(try String(contentsOf: file("sessions.json.imported-\(day)-2"), encoding: .utf8) == older)
        #expect(try reader().rows().map(\.id) == ["alpha", "older"])
        let fifth = launch()
        #expect(fifth.sessions.map(\.info.id) == ["alpha", "older"])
        #expect(!FileManager.default.fileExists(atPath: file("sessions.json.imported-\(day)-3").path))
    }

    /// Back to 0.72 and up again: a session made on this build since the
    /// import, with its history, is still there, a pinned one still pinned,
    /// and what 0.72 changed of the sessions it has is taken; the store as
    /// it was is copied aside first.
    @Test func testADowngradeAndBackLosesNothing() throws {
        try Data(Self.sessionsJSON().utf8).write(to: file("sessions.json"))
        let first = launch()
        let made = record("made", title: "Made on 0.73")
        made.entries = [TranscriptEntry(id: "m-u1", role: .user, text: "Since the upgrade"),
                        TranscriptEntry(id: "m-r1", role: .assistant, text: "And its answer")]
        first.sessions.append(made)
        first.perform(.pin(session: "alpha"), from: nil)
        first.perform(.pin(session: "made"), from: nil)
        #expect(try reader().rows().filter(\.pinned).map(\.id) == ["alpha", "made"])

        // 0.72 reads sessions.json, renames alpha and writes it again.
        var older = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file("sessions.json"))) as? [[String: Any]])
        var info = try #require(older[1]["info"] as? [String: Any])
        info["title"] = "Alpha on 0.72"
        older[1]["info"] = info
        try JSONSerialization.data(withJSONObject: older).write(to: file("sessions.json"), options: .atomic)

        let again = launch()
        #expect(again.storeIsReadable)
        #expect(again.sessions.map(\.info.id) == ["beta", "alpha", "made"], "the store's order, what it alone has kept")
        #expect((again.session("alpha")?.info.title) == "Alpha on 0.72")
        #expect((again.session("alpha")?.info.pinned) == true, "still pinned")
        let back = try #require(again.session("made"))
        #expect(back.info.pinned)
        #expect(back.entries.map(\.id) == ["m-u1", "m-r1"], "with its history")
        #expect(logged.all.contains { $0.contains("1 it hasn't kept as they were") })

        // The store as it was before, aside, whole.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let aside = try #require(names.first(where: { $0.hasPrefix("server.sqlite.before-import-") }))
        let before = try SessionStore(path: root.appendingPathComponent(aside).path)
        #expect(try before.rows().map(\.title) == ["Beta", "Alpha", "Made on 0.73"])
        #expect(try before.rows().filter(\.pinned).map(\.id) == ["alpha", "made"])
    }

    @Test func testAFileThatCantBeReadIsLeftAndNothingIsImported() throws {
        let broken = #"[{"info":{"id":"alpha","title":"Half"#
        try Data(broken.utf8).write(to: file("sessions.json"))
        try Data("[]".utf8).write(to: file("sessions.previous.json"))
        let server = launch()
        #expect(server.sessions.isEmpty)
        #expect(!server.storeIsReadable)
        #expect(server.lastError?.contains("Could not read sessions.json") == true)
        #expect(logged.all.contains { $0.contains("Could not read sessions.json") })
        #expect(try String(contentsOf: file("sessions.json"), encoding: .utf8) == broken, "left as it is")
        #expect(FileManager.default.fileExists(atPath: file("sessions.previous.json").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.contains("imported") })
        #expect(try reader().count() == 0)
        // Nor is anything written over it meanwhile.
        server.sessions = [record("new", title: "New")]
        server.saveArchiveNow()
        #expect(try reader().count() == 0)

        // Mended, it's imported at the next start.
        try Data(Self.sessionsJSON().utf8).write(to: file("sessions.json"))
        let mended = launch()
        #expect(mended.storeIsReadable)
        #expect(mended.sessions.map(\.info.id) == ["beta", "alpha"])
    }

    @Test func testEachSessionIsWrittenOnItsOwnAndKeptThroughARestart() throws {
        let server = launch()
        let one = record("one", title: "One")
        let two = record("two", title: "Two")
        server.sessions = [one, two]
        server.saveArchiveNow()
        two.info.title = "Two, renamed"
        two.info.model = "sonnet"
        server.saveArchiveNow()
        #expect(try reader().rows().map(\.title) == ["One", "Two, renamed"])

        let again = launch()
        #expect(again.sessions.map(\.info.id) == ["one", "two"])
        #expect((again.session("two")?.info.title) == "Two, renamed")
        #expect((again.session("two")?.info.model) == "sonnet")
        #expect(!FileManager.default.fileExists(atPath: file("sessions.json").path), "no JSON store")
    }

    @Test func testArchivedAndEndedSessions() throws {
        let server = launch()
        let kept = record("kept", title: "Kept")
        let put = record("put", title: "Put away")
        let gone = record("gone", title: "Gone")
        server.sessions = [kept, put, gone]
        server.saveArchiveNow()

        server.archive(put)
        #expect(try reader().rows().map(\.archived) == [false, true, false], "written at once")
        var end = Envelope(type: "end")
        end.session = "gone"
        server.perform(end, from: nil)
        #expect(try reader().rows().map(\.id) == ["kept", "put"], "its row deleted")

        let again = launch()
        #expect(again.sessions.map(\.info.id) == ["kept", "put"])
        #expect((again.session("put")?.info.archived) == true)
        #expect((again.session("put")?.info.agentState) == .stopped)
        let back = try #require(again.session("put"))
        again.unarchive(back)
        #expect(try reader().rows().map(\.archived) == [false, false])
    }

    @Test func testUpdatesFromManyTasksAreAllKept() async throws {
        let server = launch()
        server.archiveSaveDelay = .milliseconds(20)
        let records = (0..<12).map { record("s\($0)", title: "Start \($0)") }
        server.sessions = records
        server.saveArchiveNow()
        let tasks = records.enumerated().map { index, record in
            Task { @MainActor in
                for step in 0..<6 {
                    record.info.title = "s\(index) at \(step)"
                    if step.isMultiple(of: 2) { server.saveArchive() } else { server.saveArchiveNow() }
                    await Task.yield()
                }
            }
        }
        for task in tasks { await task.value }
        try await Task.sleep(for: .milliseconds(100))
        let again = launch()
        #expect(again.sessions.map(\.info.title) == (0..<12).map { "s\($0) at 5" })

        // Two connections to the file, writing at once off the main actor.
        let path = root.appendingPathComponent("shared.sqlite").path
        let first = try SessionStore(path: path)
        let second = try SessionStore(path: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                let store = writer.isMultiple(of: 2) ? first : second
                group.addTask {
                    for n in 0..<25 {
                        try store.write(put: [SessionStore.Row(id: "w\(writer)-\(n)", position: writer * 100 + n, title: "t", archived: false, stored: "{}")])
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try first.count() == 100)
        #expect(try second.rows().count == 100)
    }

    @Test func testADatabaseFromALaterBuildIsLeftAlone() throws {
        let database = try Database(path: VisorServer.storeURL.path)
        try database.execute("PRAGMA user_version = 99")
        database.close()
        #expect(throws: SessionStore.Refusal.self) { try SessionStore(path: VisorServer.storeURL.path) }
        let server = launch()
        #expect(!server.storeIsReadable)
        #expect(server.lastError?.contains("later Visor") == true)
        server.sessions = [record("new", title: "New")]
        server.saveArchiveNow()
        let after = try Database(path: VisorServer.storeURL.path)
        #expect(try after.query("PRAGMA user_version", row: { $0.int(0) }) == [99])
        #expect(try after.query("SELECT COUNT(*) FROM sqlite_master WHERE name = 'sessions'", row: { $0.int(0) }) == [0])
    }
}
}
