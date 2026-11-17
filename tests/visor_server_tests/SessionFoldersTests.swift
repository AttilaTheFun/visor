// A folder for each session (VISOR_SESSIONS_DIR, Shireworks' primary
// container): a new session works in <dir>/<agent>/<id> whatever folder it
// asked for, one that resumes a conversation keeps its own; and a session
// moved here gets its folder with its id when the move is planned,
// whatever the client chooses: new and empty, wherever it worked before
// (no repository comes), its conversation under that folder's project and
// its Claude memory with it, never over a memory already there.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class SessionFoldersTests {
    private var server: VisorServer!
    private var root: URL!
    private var home: URL!
    private var savedHome: URL!
    private let conversation = "99999999-8888-7777-6666-555555555555"

    init() async throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-folders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path, as git gives a repository's (/private/var, not /var).
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root.appendingPathComponent("store", isDirectory: true)
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: 7996)
    }

    isolated deinit {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    private var sessions: String { root.appendingPathComponent("Sessions").path }

    private func project(_ cwd: String) -> URL {
        ClaudeSessionFiles.projectsRoot(home: home).appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
    }

    /// A repository with one commit, pushed to a remote of its own (a bare
    /// repository beside it), so it has nothing its remote doesn't.
    private func repository(_ name: String) async throws -> URL {
        let folder = home.appendingPathComponent("Developer/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("let a = 1\n".utf8).write(to: folder.appendingPathComponent("main.swift"))
        _ = await ProjectSurvey.git(["init", "-q", "-b", "main"], in: folder.path)
        _ = await ProjectSurvey.git(["add", "."], in: folder.path)
        _ = await ProjectSurvey.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "First"], in: folder.path)
        let remote = root.appendingPathComponent("remotes/\(name).git").path
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        _ = await ProjectSurvey.git(["init", "-q", "--bare"], in: remote)
        _ = await ProjectSurvey.git(["remote", "add", "origin", remote], in: folder.path)
        _ = await ProjectSurvey.git(["push", "-q", "-u", "origin", "main"], in: folder.path)
        return folder
    }

    /// Claude's conversation for a session in `cwd`, and the project's
    /// memory beside it.
    private func conversationAndMemory(cwd: String) throws {
        let folder = project(cwd)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"content":"hello"}}"#.utf8 + Data("\n".utf8)).write(to: folder.appendingPathComponent(conversation + ".jsonl"))
        try Data("- [Merge queue](merge-queue.md) — strict\n".utf8).write(to: folder.appendingPathComponent("memory/MEMORY.md"))
        try Data("the merge queue".utf8).write(to: folder.appendingPathComponent("memory/merge-queue.md"))
    }

    private func carry(_ file: MigrationFile, offer: String, plan: String) {
        var offset = 0
        repeat {
            var read = Envelope(type: "migration")
            read.migration = offer
            read.file = MigrationFile(id: file.id, place: "", size: min(4000, file.size - offset), packed: false)
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

    /// The session "S" in `cwd`, offered and planned here with a folder for
    /// each session.
    private func offerAndPlan(cwd: String) async throws -> (MigrationOffer, MigrationPlan) {
        let info = SessionInfo(id: "S", agent: .claude, cwd: cwd, title: "Moving", created: 0)
        server.sessions = [SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: conversation))]
        var ask = Envelope(type: "migration")
        ask.session = "S"
        let offered = await server.migrationOffer(ask)
        let offer = try #require(offered.offer, Comment(rawValue: offered.message ?? "no offer"))
        server.sessionFolders = SessionFolders(sessions: sessions + "/")
        var planning = Envelope(type: "migration")
        planning.offer = offer
        let planned = await server.migrationPlan(planning)
        return (offer, try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan")))
    }

    private func finish(_ offer: MigrationOffer, _ plan: MigrationPlan, cwd: String? = nil) async throws -> SessionRecord {
        for file in offer.files { carry(file, offer: offer.token, plan: plan.id) }
        var finishing = Envelope(type: "migration")
        finishing.migration = plan.id
        finishing.cwd = cwd
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type != "error", Comment(rawValue: finished.message ?? ""))
        return try #require(server.session(finished.session))
    }

    // MARK: Tests

    @Test func testAFolderIsTheAgentsThenTheSessions() {
        let folders = SessionFolders(sessions: "/Volumes/Sessions/")
        #expect(folders.folder(agent: .claude, id: "abc") == "/Volumes/Sessions/Claude/abc")
        #expect(folders.folder(agent: .codex, id: "abc") == "/Volumes/Sessions/Codex/abc")
        #expect(folders.folder(agent: .openrouter, id: "..") != "/Volumes/Sessions/OpenRouter/..")
    }

    @Test func testANewSessionWorksInAFolderOfItsOwnAndAResumedOneKeepsItsFolder() throws {
        server.sessionFolders = SessionFolders(sessions: sessions)
        var start = Envelope(type: "start")
        start.id = "new1"
        start.agent = .claude
        start.cwd = "/Users/logan/Developer/visor"
        server.perform(start, from: nil)
        let made = try #require(server.session("new1"))
        #expect(made.info.cwd == (sessions + "/Claude/new1"))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: made.info.cwd, isDirectory: &isFolder) && isFolder.boolValue)

        var resume = Envelope(type: "start")
        resume.id = "old1"
        resume.agent = .claude
        resume.cwd = home.path
        resume.resume = conversation
        server.perform(resume, from: nil)
        #expect((server.session("old1")?.info.cwd) == home.path, "its conversation is kept under its folder")
    }

    @Test func testAMovedSessionGetsItsFolderAndIdFromThePlanItsConversationAndItsMemory() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (offer, plan) = try await offerAndPlan(cwd: app.path)
        #expect(offer.files.contains { $0.id == VisorServer.memoryFileID && $0.place.isEmpty && $0.packed }, "the memory carried with no place, which an older server leaves be")
        #expect(plan.cwd.hasPrefix(sessions + "/Claude/"), Comment(rawValue: plan.cwd))

        let moved = try await finish(offer, plan, cwd: "/somewhere/else")
        #expect(moved.info.cwd == plan.cwd, "the plan's folder, not the client's")
        #expect(moved.info.id == ((plan.cwd as NSString).lastPathComponent), "the id the folder was made of")
        #expect(moved.process.resumeID == conversation)
        let placed = project(plan.cwd)
        #expect(FileManager.default.fileExists(atPath: placed.appendingPathComponent(conversation + ".jsonl").path))
        #expect((try String(contentsOf: placed.appendingPathComponent("memory/merge-queue.md"), encoding: .utf8)) == "the merge queue")
        #expect((try? String(contentsOf: placed.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8)) != nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: plan.cwd)).isEmpty, "new and empty: the repository stays behind")
        #expect(!FileManager.default.fileExists(atPath: "/somewhere/else"))
    }

    /// A session whose checkout has what its remote doesn't (an untracked
    /// .env) moves all the same: nothing of the checkout comes.
    @Test func testACheckoutWithUnsharedWorkStaysBehindAndTheMoveGoesOn() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        try Data("SECRET=1\n".utf8).write(to: app.appendingPathComponent(".env"))
        let (offer, plan) = try await offerAndPlan(cwd: app.path)
        let moved = try await finish(offer, plan)
        #expect((try FileManager.default.contentsOfDirectory(atPath: moved.info.cwd)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent(".env").path), "left where it was")
    }

    @Test func testAMemoryAlreadyThereIsNeverOverwritten() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (offer, plan) = try await offerAndPlan(cwd: app.path)
        let mine = project(plan.cwd).appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: mine.appendingPathComponent("merge-queue.md"))
        _ = try await finish(offer, plan)
        #expect((try String(contentsOf: mine.appendingPathComponent("merge-queue.md"), encoding: .utf8)) == "mine")
        #expect(!(FileManager.default.fileExists(atPath: mine.appendingPathComponent("MEMORY.md").path)))
    }
}
}
