// Sessions given another working directory (FolderMove, `visor-server
// move-folder`): Visor's records and resume commands, Claude Code's projects
// merged with their memories (a clashing file renamed, the indexes combined
// under the folder each came from), its prompt history and ~/.claude.json,
// Codex's rollouts; only the folders asked for; nothing changed by a plan.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

final class FolderMoveTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var projects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func session(_ id: String, _ agent: AgentKind, in folder: String, resume: String?) -> StoredSession {
        var info = SessionInfo(id: id, agent: agent, cwd: folder, title: "Session \(id)",
                               resumeCommand: resume.map { "cd \(folder) && claude --resume \($0)" }, created: 1_700_000_000)
        info.agentState = .running
        return StoredSession(info: info, entries: [], resumeID: resume, shape: 2)
    }

    private func write(_ text: String, _ path: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }

    private func stored() throws -> [StoredSession] {
        try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: data.appendingPathComponent("sessions.json")))
    }

    /// Three sessions in two folders of the Mac's, and one already in the
    /// target; each Claude project with its transcript and memory, two
    /// memories clashing by name.
    private func fixture() throws {
        let sessions = [
            session("visor", .claude, in: "/Users/logan/Developer/visor", resume: "aaaa-1"),
            session("manager", .claude, in: "/Users/logan/Developer", resume: "bbbb-2"),
            session("monitor", .claude, in: "/Users/logan/Developer/", resume: nil),
            session("codex", .codex, in: "/Users/logan/Developer/visor", resume: "cccc-3"),
            session("there", .claude, in: "/Volumes/Sessions", resume: "dddd-4"),
        ]
        try JSONEncoder().encode(sessions).write(to: data.appendingPathComponent("sessions.json"))
        try JSONEncoder().encode(Array(sessions.prefix(2))).write(to: data.appendingPathComponent("sessions.previous.json"))
        try write("{\"type\":\"user\"}\n", ".claude/projects/-Users-logan-Developer-visor/aaaa-1.jsonl")
        try write("{}", ".claude/projects/-Users-logan-Developer-visor/aaaa-1/subagents/agent-1.jsonl")
        try write("- [Merge queue](merge-queue.md) — strict\n- [Ports](ports.md) — close them\n",
                  ".claude/projects/-Users-logan-Developer-visor/memory/MEMORY.md")
        try write("visor's merge queue", ".claude/projects/-Users-logan-Developer-visor/memory/merge-queue.md")
        try write("same everywhere", ".claude/projects/-Users-logan-Developer-visor/memory/ports.md")
        try write("{\"type\":\"user\"}\n", ".claude/projects/-Users-logan-Developer/bbbb-2.jsonl")
        try write("- [Merge queue](merge-queue.md) — the manager's\n- [Ports](ports.md) — close them\n",
                  ".claude/projects/-Users-logan-Developer/memory/MEMORY.md")
        try write("the manager's merge queue", ".claude/projects/-Users-logan-Developer/memory/merge-queue.md")
        try write("same everywhere", ".claude/projects/-Users-logan-Developer/memory/ports.md")
        try write("{}", ".claude/projects/-Users-logan-Developer-rea/eeee-5.jsonl")
        try write("{\"display\":\"hi\",\"project\":\"/Users/logan/Developer/visor\"}\n{\"display\":\"there\",\"project\":\"/elsewhere\"}\n",
                  ".claude/history.jsonl")
        try write("{\"userID\":\"u\",\"projects\":{\"/Users/logan/Developer\":{\"allowedTools\":[]},\"/elsewhere\":{}}}", ".claude.json")
        try write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"cccc-3\",\"cwd\":\"/Users/logan/Developer/visor\"}}\n{\"type\":\"turn\"}\n",
                  ".codex/sessions/2026/11/11/rollout-2026-11-11T10-00-00-cccc-3.jsonl")
    }

    // MARK: Tests

    func testClaudesKeyIsTheFolderWithEveryOtherCharacterADash() {
        XCTAssertEqual(FolderMove.claudeKey("/Users/logan/Developer/visor"), "-Users-logan-Developer-visor")
        XCTAssertEqual(FolderMove.claudeKey("/Volumes/Sessions"), "-Volumes-Sessions")
        XCTAssertEqual(FolderMove.claudeKey("/tmp/a_b.c"), "-tmp-a-b-c")
        XCTAssertEqual(FolderMove.claudeKey("/é"), "--", "a non-ASCII character a dash per UTF-16 unit")
    }

    func testAPlanChangesNothingAndSaysWhatAMoveWould() throws {
        try fixture()
        let before = try Data(contentsOf: data.appendingPathComponent("sessions.json"))
        let plan = try FolderMove(target: "/Volumes/Sessions/", home: home, data: data).plan()
        XCTAssertEqual(plan.sessions.map(\.id), ["visor", "manager", "monitor", "codex"], "not the one already there")
        XCTAssertEqual(plan.sessions.map(\.conversationFound), [true, true, nil, true])
        XCTAssertEqual(plan.claudeProjects, ["-Users-logan-Developer", "-Users-logan-Developer-visor"])
        XCTAssertEqual(plan.claudeProjectsLeft, ["-Users-logan-Developer-rea"])
        XCTAssertEqual(plan.memoryRenames, ["-Users-logan-Developer-visor/memory/merge-queue.md": "visor-merge-queue.md"])
        XCTAssertEqual(plan.historyLines, 1)
        XCTAssertEqual(plan.claudeConfigProjects, ["/Users/logan/Developer"])
        XCTAssertEqual(plan.codexRollouts.count, 1)
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("sessions.json")), before)
        XCTAssertNotNil(read(".claude/projects/-Users-logan-Developer-visor/aaaa-1.jsonl"))
    }

    func testAMoveRewritesTheRecordsAndMergesClaudesProjectsKeepingEveryMemory() throws {
        try fixture()
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data)
        try move.apply(try move.plan())

        let sessions = try stored()
        XCTAssertEqual(Set(sessions.map(\.info.cwd)), ["/Volumes/Sessions"])
        XCTAssertEqual(sessions.first { $0.info.id == "visor" }?.info.resumeCommand, "cd /Volumes/Sessions && claude --resume aaaa-1")
        let previous = try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: data.appendingPathComponent("sessions.previous.json")))
        XCTAssertEqual(Set(previous.map(\.info.cwd)), ["/Volumes/Sessions"])

        let target = ".claude/projects/-Volumes-Sessions/"
        XCTAssertNotNil(read(target + "aaaa-1.jsonl"))
        XCTAssertNotNil(read(target + "aaaa-1/subagents/agent-1.jsonl"))
        XCTAssertNotNil(read(target + "bbbb-2.jsonl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.appendingPathComponent("-Users-logan-Developer-visor").path))
        XCTAssertNotNil(read(".claude/projects/-Users-logan-Developer-rea/eeee-5.jsonl"), "a project no session names stays")

        XCTAssertEqual(read(target + "memory/merge-queue.md"), "the manager's merge queue")
        XCTAssertEqual(read(target + "memory/visor-merge-queue.md"), "visor's merge queue")
        XCTAssertEqual(read(target + "memory/ports.md"), "same everywhere")
        let index = try XCTUnwrap(read(target + "memory/MEMORY.md"))
        XCTAssertTrue(index.contains("## From /Users/logan/Developer\n\n- [Merge queue](merge-queue.md) — the manager's"), index)
        XCTAssertTrue(index.contains("## From /Users/logan/Developer/visor\n\n- [Merge queue](visor-merge-queue.md) — strict"), index)

        let history = try XCTUnwrap(read(".claude/history.jsonl"))
        XCTAssertTrue(history.contains("\"project\":\"/Volumes/Sessions\""), history)
        XCTAssertTrue(history.contains("/elsewhere"))
        let config = try XCTUnwrap(read(".claude.json"))
        XCTAssertTrue(config.contains("\"/Volumes/Sessions\""), config)
        XCTAssertFalse(config.contains("\"/Users/logan/Developer\""), config)
        XCTAssertTrue(config.contains("userID"), "the rest kept")
        let rollout = try XCTUnwrap(read(".codex/sessions/2026/11/11/rollout-2026-11-11T10-00-00-cccc-3.jsonl"))
        XCTAssertTrue(rollout.hasPrefix("{\"payload\":{\"cwd\":\"/Volumes/Sessions\",\"id\":\"cccc-3\"},\"type\":\"session_meta\"}\n{\"type\":\"turn\"}"), rollout)
    }

    func testOnlyTheFoldersAskedForMove() throws {
        try fixture()
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data, from: ["/Users/logan/Developer/visor"])
        let plan = try move.plan()
        XCTAssertEqual(plan.sessions.map(\.id), ["visor", "codex"])
        XCTAssertEqual(plan.claudeProjects, ["-Users-logan-Developer-visor"])
        try move.apply(plan)
        XCTAssertEqual(try stored().first { $0.info.id == "manager" }?.info.cwd, "/Users/logan/Developer")
        XCTAssertNotNil(read(".claude/projects/-Users-logan-Developer/bbbb-2.jsonl"))
        let index = try XCTUnwrap(read(".claude/projects/-Volumes-Sessions/memory/MEMORY.md"))
        XCTAssertFalse(index.contains("## From"), "one index moves as it is")
    }

    func testAFileAlreadyInTheTargetIsLeftWhereItWas() throws {
        try fixture()
        try write("already", ".claude/projects/-Volumes-Sessions/bbbb-2.jsonl")
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data)
        let done = try move.apply(try move.plan())
        XCTAssertEqual(read(".claude/projects/-Volumes-Sessions/bbbb-2.jsonl"), "already")
        XCTAssertNotNil(read(".claude/projects/-Users-logan-Developer/bbbb-2.jsonl"), "kept, and said")
        XCTAssertTrue(done.contains { $0.contains("left (already there): bbbb-2.jsonl") }, "\(done)")
    }
}
