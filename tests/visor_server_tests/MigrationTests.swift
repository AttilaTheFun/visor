// Moving a session to another server, both ends on one server here: the
// offer names the conversation's file and the projects the conversation
// works in; a project packed for copying carries what git tracks and does
// not ignore, and its history; the plan says what happens to each project
// where the session goes (here already, cloned, copied, made); and the end
// puts the conversation where the agent looks and starts a session on it,
// told where it came from.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class MigrationTests {
    private var server: VisorServer!
    private var home: URL!
    private var savedHome: URL!
    private let conversation = "11111111-2222-3333-4444-555555555555"

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-migration-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        // The real path, as git gives a repository's (/private/var, not /var).
        let made = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: 7995)
    }

    isolated deinit {
        ClaudeSessionFiles.home = savedHome
    }

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) async -> String? {
        await ProjectSurvey.git(arguments, in: folder.path)
    }

    /// A repository with a commit, a file git does not track yet, and a
    /// build folder it ignores.
    private func repository(_ name: String) async throws -> URL {
        let folder = home.appendingPathComponent("Developer/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("build/\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        try Data("let a = 1\n".utf8).write(to: folder.appendingPathComponent("main.swift"))
        try Data(count: 1 << 20).write(to: folder.appendingPathComponent("build/big.bin"))
        await git(["init", "-q"], in: folder)
        await git(["add", "."], in: folder)
        await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "First"], in: folder)
        try Data("not yet committed\n".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        return folder
    }

    /// Claude's file for the conversation, naming the other project three
    /// times and its own once.
    private func conversationFile(cwd: URL, other: URL) throws -> URL {
        let folder = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"content":"Read \#(cwd.path)/main.swift"}}"#,
            #"{"type":"assistant","message":{"content":"Also \#(other.path)/Sources/x.swift and \#(other.path)/README.md"}}"#,
            #"{"type":"user","message":{"content":"cd \#(other.path) && swift build"}}"#,
        ]
        let file = folder.appendingPathComponent(conversation + ".jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    /// A file of an offer's, read a piece at a time and written to a move
    /// the same way, as a client carries it.
    private func carry(_ file: MigrationFile, offer: String, plan: String) {
        var offset = 0
        repeat {
            var read = Envelope(type: "migration")
            read.migration = offer
            read.file = MigrationFile(id: file.id, place: "", size: min(1000, file.size - offset), packed: false)
            read.offset = offset
            let piece = server.migrationRead(read)
            #expect(piece.type != "error", Comment(rawValue: piece.message ?? ""))
            var write = Envelope(type: "migration")
            write.migration = plan
            write.file = file
            write.offset = offset
            write.data = piece.data
            #expect(server.migrationWrite(write).type != "error")
            offset = piece.offset ?? file.size
        } while offset < file.size
    }

    @Test func testASessionMovesWithItsConversationAndProjects() async throws {
        let cwd = try await repository("app")
        let other = try await repository("library")
        let file = try conversationFile(cwd: cwd, other: other)
        let info = SessionInfo(id: "S", agent: .claude, cwd: cwd.path, title: "Moving", created: 0)
        server.sessions = [SessionRecord(info: info, process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))]

        var ask = Envelope(type: "migration")
        ask.session = "S"
        let offered = await server.migrationOffer(ask)
        let offer = try #require(offered.offer, Comment(rawValue: offered.message ?? "no offer"))
        #expect(offer.resumeID == conversation)
        #expect(offer.files.map(\.place) == ["projects/{project}/\(conversation).jsonl"])
        #expect((offer.files.first?.size) == (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int))
        #expect(offer.projects.map(\.path) == [cwd.path, other.path], "its own folder, then the one it names")
        #expect((offer.projects.last?.mentions) == 3)
        #expect(offer.projects.allSatisfy(\.unshared), "no remote")

        // As another computer, whose home folder this is, sees it: the
        // session's folder is here; its other project is not, and has no
        // remote, so it is copied.
        try FileManager.default.moveItem(at: other, to: other.deletingLastPathComponent().appendingPathComponent("library-was"))
        var planning = Envelope(type: "migration")
        planning.offer = offer
        let planned = await server.migrationPlan(planning)
        let plan = try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan"))
        #expect(plan.cwd == cwd.path)
        #expect(plan.steps.map(\.action) == [.present, .copy])
        #expect(plan.steps.map(\.chosen) == [true, true])
        #expect((plan.steps.first?.note) == "Here already, at the same commit.")
        #expect(plan.steps.last?.note.contains("it has no remote") == true)

        // The project, packed where it was and carried.
        try FileManager.default.moveItem(at: other.deletingLastPathComponent().appendingPathComponent("library-was"), to: other)
        var packing = Envelope(type: "migration")
        packing.migration = offer.token
        packing.path = other.path
        let packing2 = await server.migrationPack(packing)
        let packed = try #require(packing2.file, Comment(rawValue: packing2.message ?? "not packed"))
        carry(packed, offer: offer.token, plan: plan.id)
        try FileManager.default.removeItem(at: other)
        var unpacking = Envelope(type: "migration")
        unpacking.migration = plan.id
        unpacking.file = packed
        unpacking.steps = [plan.steps[1]]
        let unpacked = await server.migrationUnpack(unpacking)
        #expect(unpacked.type != "error", Comment(rawValue: unpacked.message ?? ""))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("notes.txt").path), "not yet committed, still carried")
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("main.swift").path))
        #expect(!(FileManager.default.fileExists(atPath: other.appendingPathComponent("build/big.bin").path)), "ignored, not carried")
        let log = await git(["log", "--format=%s"], in: other)
        #expect(log == "First", "with its history")

        // The conversation, then the end.
        for conversationFile in offer.files { carry(conversationFile, offer: offer.token, plan: plan.id) }
        var finishing = Envelope(type: "migration")
        finishing.migration = plan.id
        finishing.steps = plan.steps
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type != "error", Comment(rawValue: finished.message ?? ""))
        let moved = try #require(server.session(finished.session))
        #expect(moved.info.id != "S")
        #expect(moved.info.title == "Moving")
        #expect(moved.info.cwd == cwd.path)
        #expect(moved.process.resumeID == conversation)
        #expect(moved.notice?.hasPrefix("Moved here from \(server.hostName).") == true, Comment(rawValue: moved.notice ?? ""))
        #expect(server.session("S") != nil, "the session it came from is left as it was")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func testASessionMovesIntoTheFolderTheUserChose() async throws {
        // Started in the home folder; to live in its repository from here on.
        let repository = try await repository("noson")
        let file = try conversationFile(cwd: home, other: repository)
        let info = SessionInfo(id: "H", agent: .claude, cwd: home.path, title: "Noson", created: 0)
        server.sessions = [SessionRecord(info: info, process: ClaudeProcess(cwd: home.path, skipPermissions: true, resume: conversation))]
        var ask = Envelope(type: "migration")
        ask.session = "H"
        let offered = await server.migrationOffer(ask)
        let offer = try #require(offered.offer, Comment(rawValue: offered.message ?? "no offer"))
        #expect(offer.projects.contains { $0.path == repository.path })
        var planning = Envelope(type: "migration")
        planning.offer = offer
        let planned = await server.migrationPlan(planning)
        let plan = try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan"))
        for conversationFile in offer.files { carry(conversationFile, offer: offer.token, plan: plan.id) }
        var finishing = Envelope(type: "migration")
        finishing.migration = plan.id
        finishing.steps = plan.steps
        finishing.cwd = repository.path
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type != "error", Comment(rawValue: finished.message ?? ""))
        let moved = try #require(server.session(finished.session))
        #expect(moved.info.cwd == repository.path)
        // Claude looks for the conversation under the folder it runs in.
        let placed = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: repository.path))
            .appendingPathComponent(conversation + ".jsonl")
        #expect((try Data(contentsOf: placed)) == (try Data(contentsOf: file)))
    }

    /// A piece written again after its answer was lost (a phone's tunnel
    /// dropping mid-move) is taken as written, the same bytes; other bytes
    /// at a place already written are refused.
    @Test func testAPieceSentAgainIsTakenAsWritten() throws {
        let folder = home.appendingPathComponent("move-in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = SessionInfo(id: "S", agent: .claude, cwd: home.path, title: "Moving", created: 0)
        let offer = MigrationOffer(token: "t", from: "Mini", session: info, resumeID: conversation, home: home.path, files: [], projects: [])
        server.migrationsIn["p"] = IncomingMigration(offer: offer, plan: MigrationPlan(id: "p", cwd: home.path, agentInstalled: true, steps: []),
                                                     folder: folder, created: Date())
        func write(_ text: String, at offset: Int) -> Envelope {
            var e = Envelope(type: "migration")
            e.migration = "p"
            e.file = MigrationFile(id: "conversation-0", place: "", size: 0, packed: false)
            e.offset = offset
            e.data = Data(text.utf8).base64EncodedString()
            return server.migrationWrite(e)
        }
        #expect(write("first,", at: 0).offset == 6)
        #expect(write("second", at: 6).offset == 12)
        #expect(write("second", at: 6).offset == 12, "sent again: taken")
        #expect(write("SECOND", at: 6).type == "error", "other bytes")
        #expect(write(".", at: 12).offset == 13)
        #expect((try String(contentsOf: folder.appendingPathComponent("conversation-0"), encoding: .utf8)) == "first,second.")
    }

    @Test func testAnOfferNeedsAConversation() async {
        server.sessions = [SessionRecord(info: SessionInfo(id: "N", agent: .claude, cwd: "/tmp", title: "New", created: 0),
                                         process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))]
        var ask = Envelope(type: "migration")
        ask.session = "N"
        let offered = await server.migrationOffer(ask)
        #expect(offered.offer == nil)
        #expect(offered.message?.contains("no conversation to move yet") == true, Comment(rawValue: offered.message ?? ""))
    }

    /// In a container its computer shares folders with (the co-tenant, the
    /// Mac's ~/Developer at the same path), a path in one stays where it is,
    /// not moved under the container's own home folder; one in none has no
    /// place. Elsewhere, paths move from home to home as before.
    @Test func testInAContainerAPathInASharedFolderStaysWhereItIs() {
        let shared = ["/Users/logan/Developer"]
        #expect(VisorServer.place("/Users/logan/Developer/x", from: "/Users/logan", to: "/root", shared: shared) == "/Users/logan/Developer/x")
        #expect(VisorServer.place("/Users/logan/Developer", from: "/Users/logan", to: "/root", shared: shared) == "/Users/logan/Developer")
        #expect(VisorServer.place("/Users/logan/Projects/x", from: "/Users/logan", to: "/root", shared: shared) == nil)
        #expect(VisorServer.place("/Users/logan/Developers", from: "/Users/logan", to: "/root", shared: shared) == nil)
        #expect(VisorServer.place("/Users/a/Developer/x", from: "/Users/a", to: "/home/b", shared: ["/home/b/Developer"]) == "/home/b/Developer/x", "shared under this home folder")
        #expect(VisorServer.place("/Users/a/Developer/x", from: "/Users/a", to: "/home/b", shared: nil) == "/home/b/Developer/x")
    }

    @Test func testAContainerTakesOnlyASessionInAFolderItsComputerShares() async throws {
        let saved = ServerPlatform.current.host
        defer { ServerPlatform.current.host = saved }
        ServerPlatform.current.host = HostDetails(name: "co-tenant", system: "linux", inContainer: true, dataDirectory: home,
                                                  sharedFolders: { ["/Users/logan/Developer"] })
        func plan(cwd: String) async -> Envelope {
            let info = SessionInfo(id: "S", agent: .claude, cwd: cwd, title: "Moving", created: 0)
            var planning = Envelope(type: "migration")
            planning.offer = MigrationOffer(token: "t", from: "MacBook", session: info, resumeID: conversation, home: "/Users/logan",
                                            files: [], projects: [])
            return await server.migrationPlan(planning)
        }
        let outside = await plan(cwd: "/Users/logan/Projects/x")
        #expect(outside.plan == nil)
        #expect(outside.message?.contains("/Users/logan/Projects/x is not in one") == true, Comment(rawValue: outside.message ?? ""))
        let inside = await plan(cwd: "/Users/logan/Developer/applications")
        #expect((try #require(inside.plan, Comment(rawValue: inside.message ?? "no plan")).cwd) == "/Users/logan/Developer/applications", "the shared folder, not /root/Developer/applications")
    }

    @Test func testPathsMoveFromOneHomeToTheOther() {
        #expect(VisorServer.path("/Users/a/Developer/x", from: "/Users/a", to: "/home/b") == "/home/b/Developer/x")
        #expect(VisorServer.path("/Users/a", from: "/Users/a", to: "/home/b") == "/home/b")
        #expect(VisorServer.path("/Users/ab/x", from: "/Users/a", to: "/home/b") == "/Users/ab/x")
        #expect(VisorServer.path("/opt/x", from: "/Users/a", to: "/home/b") == "/opt/x")
    }
}
}
