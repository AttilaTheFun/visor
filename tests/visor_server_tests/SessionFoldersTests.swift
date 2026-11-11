// A folder for each session (VISOR_SESSIONS_DIR, Shireworks' primary
// container): a new session works in <dir>/<agent>/<id> whatever folder it
// asked for, one that resumes a conversation keeps its own; a session moved
// here gets its folder with its id when the move is planned, whatever the
// client chooses, its conversation under that folder's project and its
// Claude memory with it, never over a memory already there; and its
// repositories go to the sources by name (VISOR_SOURCES_DIR), a folder
// that isn't one staying behind, each cloned from its remote and never
// copied: a session whose checkout has what its remote doesn't is refused.

import ClaudeTranscript
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class SessionFoldersTests: ServerTestCase {
    private var server: VisorServer!
    private var root: URL!
    private var home: URL!
    private var savedHome: URL!
    private let conversation = "99999999-8888-7777-6666-555555555555"

    override func setUp() async throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-folders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path, as git gives a repository's (/private/var, not /var).
        root = URL(fileURLWithPath: String(cString: try XCTUnwrap(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root.appendingPathComponent("store", isDirectory: true)
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: 7996)
    }

    override func tearDown() async throws {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    private var sessions: String { root.appendingPathComponent("Sessions").path }
    private var sources: String { root.appendingPathComponent("Sources").path }

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
            XCTAssertNotEqual(piece.type, "error", piece.message ?? "")
            var write = Envelope(type: "migration")
            write.migration = plan
            write.file = file
            write.offset = offset
            write.data = piece.data
            XCTAssertNotEqual(server.migrationWrite(write).type, "error")
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
        let offer = try XCTUnwrap(offered.offer, offered.message ?? "no offer")
        server.sessionFolders = SessionFolders(sessions: sessions + "/", sources: sources)
        var planning = Envelope(type: "migration")
        planning.offer = offer
        let planned = await server.migrationPlan(planning)
        return (offer, try XCTUnwrap(planned.plan, planned.message ?? "no plan"))
    }

    private func finish(_ offer: MigrationOffer, _ plan: MigrationPlan, cwd: String? = nil) async throws -> SessionRecord {
        for file in offer.files { carry(file, offer: offer.token, plan: plan.id) }
        var finishing = Envelope(type: "migration")
        finishing.migration = plan.id
        finishing.steps = plan.steps.filter(\.chosen)
        finishing.cwd = cwd
        let finished = await server.migrationFinish(finishing)
        XCTAssertNotEqual(finished.type, "error", finished.message ?? "")
        return try XCTUnwrap(server.session(finished.session))
    }

    // MARK: Tests

    func testAFolderIsTheAgentsThenTheSessionsAndARepositoryGoesToTheSourcesByName() {
        let folders = SessionFolders(sessions: "/Volumes/Sessions/", sources: "/Volumes/Sources")
        XCTAssertEqual(folders.folder(agent: .claude, id: "abc"), "/Volumes/Sessions/Claude/abc")
        XCTAssertEqual(folders.folder(agent: .codex, id: "abc"), "/Volumes/Sessions/Codex/abc")
        XCTAssertEqual(folders.source(for: "/Users/logan/Developer/visor/"), "/Volumes/Sources/visor")
        XCTAssertNil(SessionFolders(sessions: "/Volumes/Sessions").source(for: "/Users/logan/Developer/visor"))
    }

    func testANewSessionWorksInAFolderOfItsOwnAndAResumedOneKeepsItsFolder() throws {
        server.sessionFolders = SessionFolders(sessions: sessions)
        var start = Envelope(type: "start")
        start.id = "new1"
        start.agent = .claude
        start.cwd = "/Users/logan/Developer/visor"
        server.perform(start, from: nil)
        let made = try XCTUnwrap(server.session("new1"))
        XCTAssertEqual(made.info.cwd, sessions + "/Claude/new1")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.info.cwd, isDirectory: &isFolder) && isFolder.boolValue)

        var resume = Envelope(type: "start")
        resume.id = "old1"
        resume.agent = .claude
        resume.cwd = home.path
        resume.resume = conversation
        server.perform(resume, from: nil)
        XCTAssertEqual(server.session("old1")?.info.cwd, home.path, "its conversation is kept under its folder")
    }

    func testAMovedSessionGetsItsFolderAndIdFromThePlanItsConversationAndItsMemory() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (offer, plan) = try await offerAndPlan(cwd: app.path)
        XCTAssertTrue(offer.files.contains { $0.id == VisorServer.memoryFileID && $0.place.isEmpty && $0.packed },
                      "the memory carried with no place, which an older server leaves be")
        XCTAssertTrue(plan.cwd.hasPrefix(sessions + "/Claude/"), plan.cwd)
        XCTAssertEqual(plan.steps.map(\.path), [sources + "/app"], "its repository, by name, under the sources")
        XCTAssertEqual(plan.steps.map(\.chosen), [true])

        let moved = try await finish(offer, plan, cwd: "/somewhere/else")
        XCTAssertEqual(moved.info.cwd, plan.cwd, "the plan's folder, not the client's")
        XCTAssertEqual(moved.info.id, (plan.cwd as NSString).lastPathComponent, "the id the folder was made of")
        XCTAssertEqual(moved.process.resumeID, conversation)
        let placed = project(plan.cwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent(conversation + ".jsonl").path))
        XCTAssertEqual(try String(contentsOf: placed.appendingPathComponent("memory/merge-queue.md"), encoding: .utf8), "the merge queue")
        XCTAssertNotNil(try? String(contentsOf: placed.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8))
    }

    func testAFolderThatIsNotARepositoryStaysBehind() async throws {
        let plain = home.appendingPathComponent("Developer", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try conversationAndMemory(cwd: plain.path)
        let (_, plan) = try await offerAndPlan(cwd: plain.path)
        XCTAssertTrue(plan.steps.isEmpty, "\(plan.steps)")
        XCTAssertTrue(plan.cwd.hasPrefix(sessions + "/Claude/"))
    }

    func testASessionWhoseCheckoutHasWhatItsRemoteDoesntIsRefused() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        // An untracked file (a .env) is never carried into the sources.
        try Data("SECRET=1\n".utf8).write(to: app.appendingPathComponent(".env"))
        let info = SessionInfo(id: "S", agent: .claude, cwd: app.path, title: "Moving", created: 0)
        server.sessions = [SessionRecord(info: info, process: ClaudeProcess(cwd: app.path, skipPermissions: true, resume: conversation))]
        var ask = Envelope(type: "migration")
        ask.session = "S"
        let offered = await server.migrationOffer(ask)
        let offer = try XCTUnwrap(offered.offer, offered.message ?? "no offer")
        server.sessionFolders = SessionFolders(sessions: sessions, sources: sources)
        var planning = Envelope(type: "migration")
        planning.offer = offer
        let planned = await server.migrationPlan(planning)
        XCTAssertNil(planned.plan)
        XCTAssertTrue(planned.message?.contains("commit and push it") == true, planned.message ?? "")
    }

    func testNothingIsCopiedIntoTheSources() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (_, plan) = try await offerAndPlan(cwd: app.path)
        XCTAssertEqual(plan.steps.map(\.action), [.clone])
        var unpacking = Envelope(type: "migration")
        unpacking.migration = plan.id
        unpacking.file = MigrationFile(id: "project-0", place: "", size: 0, packed: true)
        unpacking.steps = plan.steps
        let refused = await server.migrationUnpack(unpacking)
        XCTAssertEqual(refused.type, "error")
        XCTAssertTrue(refused.message?.contains("never copied") == true, refused.message ?? "")
    }

    func testARepositoryComesIntoTheSourcesAsAFreshCloneOfItsRemote() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (_, plan) = try await offerAndPlan(cwd: app.path)
        var cloning = Envelope(type: "migration")
        cloning.migration = plan.id
        cloning.steps = plan.steps
        let cloned = await server.migrationClone(cloning)
        XCTAssertNotEqual(cloned.type, "error", cloned.message ?? "")
        let clone = URL(fileURLWithPath: sources + "/app", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("main.swift").path))
        let branch = await ProjectSurvey.git(["rev-parse", "--abbrev-ref", "HEAD"], in: clone.path)
        XCTAssertEqual(branch, "main", "the session's branch")
    }

    func testGitHubOverSSHIsClonedOverHTTPS() {
        XCTAssertEqual(VisorServer.overHTTPS("git@github.com:AttilaTheFun/visor.git"), "https://github.com/AttilaTheFun/visor.git")
        XCTAssertEqual(VisorServer.overHTTPS("ssh://git@github.com/AttilaTheFun/visor"), "https://github.com/AttilaTheFun/visor")
        XCTAssertEqual(VisorServer.overHTTPS("https://github.com/AttilaTheFun/visor.git"), "https://github.com/AttilaTheFun/visor.git")
    }

    func testAMemoryAlreadyThereIsNeverOverwritten() async throws {
        let app = try await repository("app")
        try conversationAndMemory(cwd: app.path)
        let (offer, plan) = try await offerAndPlan(cwd: app.path)
        let mine = project(plan.cwd).appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: mine.appendingPathComponent("merge-queue.md"))
        _ = try await finish(offer, plan)
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("merge-queue.md"), encoding: .utf8), "mine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.appendingPathComponent("MEMORY.md").path))
    }
}
