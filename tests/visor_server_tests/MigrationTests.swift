// Moving a session to another server, both ends on one server here: the
// offer names the agent's own files for the conversation (its transcript,
// the folder beside it, Claude's memory) and nothing else; the plan says
// where the session runs here, a new, empty folder of this server's
// choosing; the files are carried a piece at a time, never past the size
// each was offered as; and the end puts them where the agent here keeps
// that conversation for the new folder and starts a session on it, told
// where it came from. No path of the other server's, or of the client's,
// is used; a move over the caps, or one that would not fit, is refused;
// and the project steps of before are gone.

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
    private var root: URL!
    private var home: URL!
    private var savedHome: URL!
    private let conversation = "11111111-2222-3333-4444-555555555555"

    init() async throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-migration-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: 7995)
    }

    isolated deinit {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    private func project(_ cwd: String) -> URL {
        ClaudeSessionFiles.projectsRoot(home: home).appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
    }

    /// A session's folder with a project in it (a file, and Claude's
    /// settings with a hook), Claude's file for its conversation, the
    /// folder beside it (a subagent's record), and the project's memory.
    private func session(_ id: String) throws -> (cwd: URL, file: URL) {
        let cwd = home.appendingPathComponent("Developer/app", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("let a = 1\n".utf8).write(to: cwd.appendingPathComponent("main.swift"))
        try Data(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /tmp/hooked"}]}]}}"#.utf8)
            .write(to: cwd.appendingPathComponent(".claude/settings.json"))
        let folder = project(cwd.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("\(conversation)/subagents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("memory"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(conversation + ".jsonl")
        try Data((#"{"type":"user","message":{"content":"Read \#(cwd.path)/main.swift"}}"# + "\n").utf8).write(to: file)
        try Data("a subagent\n".utf8).write(to: folder.appendingPathComponent("\(conversation)/subagents/agent-1.jsonl"))
        try Data("- [Merge queue](merge-queue.md)\n".utf8).write(to: folder.appendingPathComponent("memory/MEMORY.md"))
        let info = SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: "Moving", created: 0)
        server.sessions = [SessionRecord(info: info, process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))]
        return (cwd, file)
    }

    private func offer(of session: String) async throws -> MigrationOffer {
        var ask = Envelope(type: "migration")
        ask.session = session
        let offered = await server.migrationOffer(ask)
        return try #require(offered.offer, Comment(rawValue: offered.message ?? "no offer"))
    }

    private func plan(_ offer: MigrationOffer) async -> Envelope {
        var planning = Envelope(type: "migration")
        planning.offer = offer
        return await server.migrationPlan(planning)
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
            let written = server.migrationWrite(write)
            #expect(written.type != "error", Comment(rawValue: written.message ?? ""))
            offset = piece.offset ?? file.size
        } while offset < file.size
    }

    private func everything(under folder: URL) -> Set<String> {
        var found: Set<String> = []
        var folders = [folder.path]
        while let at = folders.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: at)) ?? [] {
                let path = at + "/" + name
                found.insert(path)
                if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory { folders.append(path) }
            }
        }
        return found
    }

    // MARK: A move end to end

    @Test func testASessionMovesWithItsTranscriptAndMemoryIntoANewEmptyFolder() async throws {
        let (cwd, file) = try session("S")
        let offer = try await offer(of: "S")
        #expect(offer.resumeID == conversation)
        #expect(offer.files.map(\.place) == ["projects/{project}/\(conversation).jsonl", "projects/{project}/\(conversation)", ""])
        #expect(offer.files.map(\.id) == ["conversation-0", "conversation-1", VisorServer.memoryFileID])
        #expect((offer.files.first?.size) == (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int))
        #expect(offer.json["projects"] == .null, "no projects offered")

        let planned = await plan(offer)
        let plan = try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan"))
        #expect(plan.cwd.hasPrefix(VisorServer.movedSessionsFolder.path + "/Claude/"), Comment(rawValue: plan.cwd))
        #expect(plan.cwd != cwd.path, "a new folder, never the one it worked in")
        #expect(plan.json["steps"] == .null)

        for carried in offer.files { carry(carried, offer: offer.token, plan: plan.id) }
        var finishing = Envelope(type: "migration")
        finishing.migration = plan.id
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type != "error", Comment(rawValue: finished.message ?? ""))
        let moved = try #require(server.session(finished.session))
        #expect(moved.info.id != "S")
        #expect(moved.info.id == (plan.cwd as NSString).lastPathComponent, "the id the folder was made of")
        #expect(moved.info.title == "Moving")
        #expect(moved.info.cwd == plan.cwd)
        #expect(moved.process.resumeID == conversation)
        #expect(moved.notice?.hasPrefix("Moved here from \(server.hostName).") == true, Comment(rawValue: moved.notice ?? ""))

        // The transcript, its folder and the memory, under the new folder's
        // project, where Claude looks for them.
        let placed = project(plan.cwd)
        #expect((try Data(contentsOf: placed.appendingPathComponent(conversation + ".jsonl"))) == (try Data(contentsOf: file)))
        #expect((try String(contentsOf: placed.appendingPathComponent("\(conversation)/subagents/agent-1.jsonl"), encoding: .utf8)) == "a subagent\n")
        #expect((try String(contentsOf: placed.appendingPathComponent("memory/MEMORY.md"), encoding: .utf8)) == "- [Merge queue](merge-queue.md)\n")
        // The working folder made, and empty: no project, no settings, no hooks.
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: plan.cwd, isDirectory: &isFolder) && isFolder.boolValue)
        #expect((try FileManager.default.contentsOfDirectory(atPath: plan.cwd)).isEmpty)
        // The session it came from is left as it was.
        #expect(server.session("S") != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("main.swift").path))
    }

    // MARK: No path of the peer's or the client's

    /// The offer's folder and home, and a client's own folder and project
    /// steps (as a client before 0.61 sends them), name nothing here: the
    /// session runs in the plan's new folder, and nothing is made where
    /// they point.
    @Test func testAPeerOrClientNamesNoDestinationPath() async throws {
        _ = try session("S")
        var offer = try await offer(of: "S")
        let peerFolder = home.appendingPathComponent("peer-chosen", isDirectory: true)
        let clientFolder = home.appendingPathComponent("client-chosen", isDirectory: true)
        offer.session.cwd = peerFolder.path
        offer.home = root.path
        let planned = await plan(offer)
        let plan = try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan"))
        #expect(plan.cwd.hasPrefix(VisorServer.movedSessionsFolder.path + "/"))
        for carried in offer.files { carry(carried, offer: offer.token, plan: plan.id) }
        let before = everything(under: home)
        let old = #"{"type":"migration","migration":"\#(plan.id)","cwd":"\#(clientFolder.path)","#
            + #""steps":[{"project":"/x","path":"\#(clientFolder.path)/repo","action":"create","note":"","chosen":true}]}"#
        let finishing = try #require(Envelope.decode(old, defaultType: "migration"))
        let finished = await server.migrationFinish(finishing)
        #expect(finished.type != "error", Comment(rawValue: finished.message ?? ""))
        #expect(server.session(finished.session)?.info.cwd == plan.cwd)
        #expect(!FileManager.default.fileExists(atPath: peerFolder.path))
        #expect(!FileManager.default.fileExists(atPath: clientFolder.path))
        // Under the home folder, only the new folder's project is new.
        let made = everything(under: home).subtracting(before)
        let placed = project(plan.cwd).path
        let elsewhere = made.filter { $0 != placed && !$0.hasPrefix(placed + "/") }
        #expect(elsewhere.isEmpty, "\(elsewhere)")
        #expect(!made.isEmpty)
    }

    /// Only the agent's own files: a file with no place but Claude's
    /// memory (a project packed, as before 0.61), a memory for another
    /// agent, or a place named twice is refused.
    @Test func testAnOfferOfAnythingButTheAgentsFilesIsRefused() async throws {
        let info = SessionInfo(id: "S", agent: .claude, cwd: home.appendingPathComponent("app").path, title: "Moving", created: 0)
        let log = MigrationFile(id: "conversation-0", place: "projects/{project}/\(conversation).jsonl", size: 1, packed: false)
        let cases: [(String, AgentKind, [MigrationFile])] = [
            ("a project", .claude, [log, MigrationFile(id: "project-0", place: "", size: 1, packed: true)]),
            ("a file with no place", .claude, [log, MigrationFile(id: "notes", place: "", size: 1, packed: false)]),
            ("a memory not packed", .claude, [log, MigrationFile(id: "memory", place: "", size: 1, packed: false)]),
            ("Codex's memory", .codex, [MigrationFile(id: "memory", place: "", size: 1, packed: true)]),
            ("a place twice", .claude, [log, MigrationFile(id: "conversation-1", place: log.place, size: 1, packed: false)]),
        ]
        for (what, agent, files) in cases {
            var session = info
            session.agent = agent
            let offer = MigrationOffer(token: "t", from: "Elsewhere", session: session, resumeID: conversation, home: home.path, files: files)
            #expect(VisorServer.unsafeOffer(offer) != nil, "\(what)")
            #expect(await plan(offer).plan == nil, "\(what)")
        }
        let project = await plan(MigrationOffer(token: "t", from: "Elsewhere", session: info, resumeID: conversation, home: home.path,
                                                files: cases[0].2))
        #expect(project.message?.contains("not one of the agent's own files") == true, Comment(rawValue: project.message ?? ""))
        let honest = await plan(MigrationOffer(token: "t", from: "Elsewhere", session: info, resumeID: conversation, home: home.path,
                                               files: [log, MigrationFile(id: "memory", place: "", size: 1, packed: true)]))
        #expect(honest.plan != nil, Comment(rawValue: honest.message ?? ""))
    }

    // MARK: Sizes

    private func offer(sizes: [Int]) -> MigrationOffer {
        let places = ["projects/{project}/\(conversation).jsonl", "projects/{project}/\(conversation)", ""]
        let files = sizes.enumerated().map { index, size in
            MigrationFile(id: index == 2 ? "memory" : "conversation-\(index)", place: places[index], size: size, packed: index > 0)
        }
        let info = SessionInfo(id: "S", agent: .claude, cwd: home.appendingPathComponent("app").path, title: "Moving", created: 0)
        return MigrationOffer(token: "t", from: "Elsewhere", session: info, resumeID: conversation, home: home.path, files: files)
    }

    @Test func testAFileOrAMoveOverItsCapIsRefused() async {
        server.freeBytes = { _ in Int.max / 2 }
        let cap = VisorServer.migrationFileCap
        #expect(VisorServer.migrationFileCap == 2 << 30)
        #expect(VisorServer.migrationTotalCap == 4 << 30)
        let file = await plan(offer(sizes: [cap + 1]))
        #expect(file.plan == nil && file.message?.contains("at most 2.0 GB of a file") == true, Comment(rawValue: file.message ?? "planned"))
        let negative = await plan(offer(sizes: [-1]))
        #expect(negative.plan == nil)
        let total = await plan(offer(sizes: [cap, cap, 1]))
        #expect(total.plan == nil && total.message?.contains("at most 4.0 GB") == true, Comment(rawValue: total.message ?? "planned"))
        let atTheCaps = await plan(offer(sizes: [cap, cap - 1, 1]))
        #expect(atTheCaps.plan != nil, Comment(rawValue: atTheCaps.message ?? ""))
    }

    @Test func testAPiecePastItsFilesDeclaredSizeIsRefused() async throws {
        let planned = await plan(offer(sizes: [10]))
        let plan = try #require(planned.plan, Comment(rawValue: planned.message ?? "no plan"))
        func write(_ id: String, _ text: String, at offset: Int) -> Envelope {
            var e = Envelope(type: "migration")
            e.migration = plan.id
            e.file = MigrationFile(id: id, place: "", size: 0, packed: false)
            e.offset = offset
            e.data = Data(text.utf8).base64EncodedString()
            return server.migrationWrite(e)
        }
        #expect(write("conversation-0", "12345678901", at: 0).type == "error", "more than offered")
        #expect(write("conversation-0", "x", at: 11).type == "error", "an offset past its size")
        #expect(write("conversation-0", "x", at: -1).type == "error")
        #expect(write("conversation-1", "x", at: 0).type == "error", "a file the offer didn't name")
        #expect(write("conversation-0", "123456", at: 0).offset == 6)
        #expect(write("conversation-0", "7890", at: 6).offset == 10, "up to its size exactly")
        #expect(write("conversation-0", "1", at: 10).type == "error", "past its end")
    }

    @Test func testAMoveThatWouldNotFitIsRefused() async throws {
        var asked: [String] = []
        server.freeBytes = { url in
            asked.append(url.path)
            return 100 << 20
        }
        let tight = await plan(offer(sizes: [10]))
        #expect(tight.plan == nil, "10 bytes, with 1 GiB to spare, in 100 MB")
        #expect(tight.message?.contains("not room for it here") == true, Comment(rawValue: tight.message ?? ""))
        #expect(asked.first == VisorServer.migrationsFolder.path)
        // Room where the move keeps the files as they come, but not under
        // the agent's folder: refused too.
        let agent = ClaudeSessionFiles.configDirectory(home: home).standardizedFileURL.path
        server.freeBytes = { url in url.standardizedFileURL.path == agent ? 100 << 20 : Int.max / 2 }
        let agentFull = await plan(offer(sizes: [10]))
        #expect(agentFull.plan == nil, Comment(rawValue: agentFull.message ?? "planned"))
        #expect(agentFull.message?.contains(agent) == true, Comment(rawValue: agentFull.message ?? ""))
        server.freeBytes = { _ in (1 << 30) + 10 }
        let room = await plan(offer(sizes: [10]))
        #expect(room.plan != nil, Comment(rawValue: room.message ?? ""))
        // Where the system doesn't say, the move goes on.
        server.freeBytes = { _ in nil }
        #expect(await plan(offer(sizes: [10])).plan != nil)
        // The system's own word, for a folder not made yet.
        #expect((VisorServer.systemFreeBytes(root.appendingPathComponent("not/made/yet")) ?? 0) > 0)
    }

    // MARK: Pieces

    /// A piece written again after its answer was lost (a phone's tunnel
    /// dropping mid-move) is taken as written, the same bytes; other bytes
    /// at a place already written are refused.
    @Test func testAPieceSentAgainIsTakenAsWritten() throws {
        let folder = home.appendingPathComponent("move-in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server.migrationsIn["p"] = IncomingMigration(offer: offer(sizes: [13]), plan: MigrationPlan(id: "p", cwd: home.path, agentInstalled: true),
                                                     folder: folder, created: Date(), sessionID: "moved")
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

    // MARK: Containers, and what was removed

    /// In a container its computer shares folders with, a session moved
    /// here works in one of them: the server's folder for each session
    /// there, or the move is refused.
    @Test func testAContainerTakesASessionOnlyIntoAFolderItsComputerShares() async throws {
        let saved = ServerPlatform.current.host
        defer { ServerPlatform.current.host = saved }
        let shared = root.appendingPathComponent("shared").path
        ServerPlatform.current.host = HostDetails(name: "co-tenant", system: "linux", inContainer: true, dataDirectory: home,
                                                  sharedFolders: { [shared] })
        let outside = await plan(offer(sizes: [10]))
        #expect(outside.plan == nil)
        #expect(outside.message?.contains("is not in one") == true, Comment(rawValue: outside.message ?? ""))
        server.sessionFolders = SessionFolders(sessions: shared + "/Sessions")
        let inside = await plan(offer(sizes: [10]))
        #expect((try #require(inside.plan, Comment(rawValue: inside.message ?? "no plan")).cwd).hasPrefix(shared + "/Sessions/Claude/"))
    }

    @Test func testTheProjectStepsAreGone() async {
        for step in ["pack", "clone", "unpack"] {
            let answer = await withCheckedContinuation { (done: CheckedContinuation<HTTPResponse, Never>) in
                server.routeMigration(step, body: Envelope(type: "migration")) { done.resume(returning: $0) }
            }
            #expect(answer.status == 410, "\(step)")
            #expect(answer.body.contains("removed in Visor 0.61"), Comment(rawValue: answer.body))
        }
    }

    @Test func testPathsMoveFromOneHomeToTheOther() {
        #expect(VisorServer.path("/Users/a/Developer/x", from: "/Users/a", to: "/home/b") == "/home/b/Developer/x")
        #expect(VisorServer.path("/Users/a", from: "/Users/a", to: "/home/b") == "/home/b")
        #expect(VisorServer.path("/Users/ab/x", from: "/Users/a", to: "/home/b") == "/Users/ab/x")
        #expect(VisorServer.path("/opt/x", from: "/Users/a", to: "/home/b") == "/opt/x")
    }
}
}
