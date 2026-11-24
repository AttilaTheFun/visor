// Sessions given another working directory (FolderMove, `visor-server
// move-folder`): Visor's records and resume commands, Claude Code's projects
// merged with their memories (a clashing file renamed, the indexes combined
// under the folder each came from), its prompt history and ~/.claude.json,
// Codex's rollouts and the OpenRouter CLI's sessions; only the folders asked
// for; nothing changed by a plan.

import Foundation
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class FolderMoveTests {
    private let root: URL
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var projects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    deinit {
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
            session("router", .openrouter, in: "/Users/logan/Developer/visor", resume: "ffff-6"),
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
        try write("{\"created\":1,\"cwd\":\"/Users/logan/Developer/visor\",\"id\":\"ffff-6\",\"messages\":[],\"model\":\"m\",\"updated\":2}",
                  ".openrouter/sessions/ffff-6.json")
    }

    // MARK: Tests

    @Test func testClaudesKeyIsTheFolderWithEveryOtherCharacterADash() {
        #expect(FolderMove.claudeKey("/Users/logan/Developer/visor") == "-Users-logan-Developer-visor")
        #expect(FolderMove.claudeKey("/Volumes/Sessions") == "-Volumes-Sessions")
        #expect(FolderMove.claudeKey("/tmp/a_b.c") == "-tmp-a-b-c")
        #expect(FolderMove.claudeKey("/é") == "--", "a non-ASCII character a dash per UTF-16 unit")
    }

    @Test func testAPlanChangesNothingAndSaysWhatAMoveWould() throws {
        try fixture()
        let before = try Data(contentsOf: data.appendingPathComponent("sessions.json"))
        let plan = try FolderMove(target: "/Volumes/Sessions/", home: home, data: data).plan()
        #expect(plan.sessions.map(\.id) == ["visor", "manager", "monitor", "codex", "router"], "not the one already there")
        #expect(plan.sessions.map(\.conversationFound) == [true, true, nil, true, true])
        #expect(plan.claudeProjects == ["-Users-logan-Developer", "-Users-logan-Developer-visor"])
        #expect(plan.claudeProjectsLeft == ["-Users-logan-Developer-rea"])
        #expect(plan.memoryRenames == ["-Users-logan-Developer-visor/memory/merge-queue.md": "visor-merge-queue.md"])
        #expect(plan.historyLines == 1)
        #expect(plan.claudeConfigProjects == ["/Users/logan/Developer"])
        #expect(plan.codexRollouts.count == 1)
        #expect(plan.openRouterSessions.count == 1)
        #expect(try Data(contentsOf: data.appendingPathComponent("sessions.json")) == before)
        #expect(read(".claude/projects/-Users-logan-Developer-visor/aaaa-1.jsonl") != nil)
    }

    @Test func testAMoveRewritesTheRecordsAndMergesClaudesProjectsKeepingEveryMemory() throws {
        try fixture()
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data)
        try move.apply(try move.plan())

        let sessions = try stored()
        #expect(Set(sessions.map(\.info.cwd)) == ["/Volumes/Sessions"])
        #expect(sessions.first { $0.info.id == "visor" }?.info.resumeCommand == "cd /Volumes/Sessions && claude --resume aaaa-1")
        let previous = try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: data.appendingPathComponent("sessions.previous.json")))
        #expect(Set(previous.map(\.info.cwd)) == ["/Volumes/Sessions"])

        let target = ".claude/projects/-Volumes-Sessions/"
        #expect(read(target + "aaaa-1.jsonl") != nil)
        #expect(read(target + "aaaa-1/subagents/agent-1.jsonl") != nil)
        #expect(read(target + "bbbb-2.jsonl") != nil)
        #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("-Users-logan-Developer-visor").path))
        #expect(read(".claude/projects/-Users-logan-Developer-rea/eeee-5.jsonl") != nil, "a project no session names stays")

        #expect(read(target + "memory/merge-queue.md") == "the manager's merge queue")
        #expect(read(target + "memory/visor-merge-queue.md") == "visor's merge queue")
        #expect(read(target + "memory/ports.md") == "same everywhere")
        let index = try #require(read(target + "memory/MEMORY.md"))
        #expect(index.contains("## From /Users/logan/Developer\n\n- [Merge queue](merge-queue.md) — the manager's"), "\(index)")
        #expect(index.contains("## From /Users/logan/Developer/visor\n\n- [Merge queue](visor-merge-queue.md) — strict"), "\(index)")

        let history = try #require(read(".claude/history.jsonl"))
        #expect(history.contains("\"project\":\"/Volumes/Sessions\""), "\(history)")
        #expect(history.contains("/elsewhere"))
        let config = try #require(read(".claude.json"))
        #expect(config.contains("\"/Volumes/Sessions\""), "\(config)")
        #expect(!config.contains("\"/Users/logan/Developer\""), "\(config)")
        #expect(config.contains("userID"), "the rest kept")
        let rollout = try #require(read(".codex/sessions/2026/11/11/rollout-2026-11-11T10-00-00-cccc-3.jsonl"))
        #expect(rollout.hasPrefix("{\"payload\":{\"cwd\":\"/Volumes/Sessions\",\"id\":\"cccc-3\"},\"type\":\"session_meta\"}\n{\"type\":\"turn\"}"), "\(rollout)")
        let router = try #require(read(".openrouter/sessions/ffff-6.json"))
        #expect(router.contains("\"cwd\":\"/Volumes/Sessions\""), "\(router)")
        #expect(router.contains("\"model\":\"m\""), "the rest kept")
    }

    @Test func testOnlyTheFoldersAskedForMove() throws {
        try fixture()
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data, from: ["/Users/logan/Developer/visor"])
        let plan = try move.plan()
        #expect(plan.sessions.map(\.id) == ["visor", "codex", "router"])
        #expect(plan.claudeProjects == ["-Users-logan-Developer-visor"])
        try move.apply(plan)
        #expect(try stored().first { $0.info.id == "manager" }?.info.cwd == "/Users/logan/Developer")
        #expect(read(".claude/projects/-Users-logan-Developer/bbbb-2.jsonl") != nil)
        let index = try #require(read(".claude/projects/-Volumes-Sessions/memory/MEMORY.md"))
        #expect(!index.contains("## From"), "one index moves as it is")
    }

    @Test func testAFileAlreadyInTheTargetIsLeftWhereItWas() throws {
        try fixture()
        try write("already", ".claude/projects/-Volumes-Sessions/bbbb-2.jsonl")
        let move = FolderMove(target: "/Volumes/Sessions", home: home, data: data)
        let done = try move.apply(try move.plan())
        #expect(read(".claude/projects/-Volumes-Sessions/bbbb-2.jsonl") == "already")
        #expect(read(".claude/projects/-Users-logan-Developer/bbbb-2.jsonl") != nil, "kept, and said")
        #expect(done.contains { $0.contains("left (already there): bbbb-2.jsonl") }, "\(done)")
    }
}
}
