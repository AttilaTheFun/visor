// One session given another working directory (FolderMove+Session: a
// session's inspector, `move-folder --session`): its Claude Code transcript
// and folder moved by id; the project's memory and ~/.claude.json entry
// copied while another session is still in the old folder, moved when none
// is, a clashing memory kept under the folder's prefix; a Codex rollout and
// an OpenRouter session given the folder; the same folder by another name
// (universal_ui, a link to isomer now) a move; and nothing changed by a plan.

import Foundation
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class SessionFolderMoveTests {
    private let root: URL
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var old: String { root.appendingPathComponent("work/old").path }
    private var new: String { root.appendingPathComponent("work/new").path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-folder-move-\(UUID().uuidString)", isDirectory: true)
        for folder in [data.path, home.path, old, new] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func session(_ id: String, _ agent: AgentKind, in folder: String, resume: String?) -> StoredSession {
        let tool = agent == .codex ? "codex resume" : "\(agent.rawValue) --resume"
        let info = SessionInfo(id: id, agent: agent, cwd: folder, title: "Session \(id)",
                               resumeCommand: resume.map { "cd \(folder) && \(tool) \($0)" }, created: 1_700_000_000)
        return StoredSession(info: info, entries: [], resumeID: resume, shape: 2)
    }

    private func store(_ sessions: [StoredSession]) throws {
        try JSONEncoder().encode(sessions).write(to: data.appendingPathComponent("sessions.json"))
    }

    private func stored() throws -> [StoredSession] {
        try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: data.appendingPathComponent("sessions.json")))
    }

    private func write(_ text: String, _ path: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? { try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

    /// Claude Code's project folder for a folder, under the home.
    private func project(_ folder: String) -> String { ".claude/projects/" + FolderMove.claudeProjectKey(folder) + "/" }

    /// Two Claude Code sessions in the old folder (the second only when
    /// `shared`), the first with a transcript folder; the project's memory
    /// and ~/.claude.json's entry; a line of prompt history.
    private func claudeFixture(shared: Bool) throws {
        try store([session("moving", .claude, in: old, resume: "aaaa")] + (shared ? [session("staying", .claude, in: old, resume: "bbbb")] : []))
        try write("{\"type\":\"user\"}\n", project(old) + "aaaa.jsonl")
        try write("{}", project(old) + "aaaa/subagents/agent-1.jsonl")
        if shared { try write("{\"type\":\"user\"}\n", project(old) + "bbbb.jsonl") }
        try write("- [Notes](notes.md) — old\n- [Same](same.md)\n", project(old) + "memory/MEMORY.md")
        try write("old notes", project(old) + "memory/notes.md")
        try write("same everywhere", project(old) + "memory/same.md")
        try write("{\"userID\":\"u\",\"projects\":{\"\(old)\":{\"allowedTools\":[\"Bash\"]}}}", ".claude.json")
        try write("{\"display\":\"hi\",\"project\":\"\(old)\"}\n", ".claude/history.jsonl")
    }

    private func moveSession(_ id: String, to folder: String) throws -> (FolderMove.SessionPlan, [String]) {
        let move = FolderMove(target: folder, home: home, data: data)
        let plan = try move.planSession(id: id)
        let done = try move.applySession(plan) + move.writeRecord(plan)
        return (plan, done)
    }

    /// Every file and folder under the root, with what each file holds.
    private func snapshot() -> [String: Data] {
        var files: [String: Data] = [:]
        guard let paths = FileManager.default.enumerator(atPath: root.path) else { return files }
        for case let path as String in paths {
            // A folder: nothing to read, but there.
            files[path] = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) ?? Data()
        }
        return files
    }

    // MARK: Tests

    @Test func testWhileAnotherSessionIsInTheOldFolderItsMemoryIsCopied() throws {
        try claudeFixture(shared: true)
        let history = read(".claude/history.jsonl")
        let (plan, done) = try moveSession("moving", to: new)
        #expect(plan.sharedWith == ["staying"])
        #expect(plan.claudeFiles == ["aaaa.jsonl", "aaaa"])
        #expect(plan.memoryFiles == ["notes.md", "same.md"])

        // The conversation moved, by id; the other session's stays.
        #expect(read(project(new) + "aaaa.jsonl") != nil)
        #expect(read(project(new) + "aaaa/subagents/agent-1.jsonl") != nil)
        #expect(!exists(project(old) + "aaaa.jsonl"))
        #expect(!exists(project(old) + "aaaa"))
        #expect(read(project(old) + "bbbb.jsonl") != nil, "the other session's transcript stays")
        #expect(!exists(project(new) + "bbbb.jsonl"))

        // The memory in both.
        #expect(read(project(old) + "memory/notes.md") == "old notes", "the old memory stays")
        #expect(read(project(old) + "memory/MEMORY.md") == "- [Notes](notes.md) — old\n- [Same](same.md)\n")
        #expect(read(project(new) + "memory/notes.md") == "old notes")
        #expect(read(project(new) + "memory/MEMORY.md") == "- [Notes](notes.md) — old\n- [Same](same.md)\n")

        // ~/.claude.json's entry in both; the history as it was.
        let config = try #require(read(".claude.json"))
        #expect(config.contains("\"\(old)\""), "\(config)")
        #expect(config.contains("\"\(FolderMove.claudeFolder(new))\""), "\(config)")
        #expect(read(".claude/history.jsonl") == history)

        // Visor's record: this session's alone.
        let sessions = try stored()
        #expect(sessions.first { $0.info.id == "moving" }?.info.cwd == new)
        #expect(sessions.first { $0.info.id == "moving" }?.info.resumeCommand == "cd \(new) && claude --resume aaaa")
        #expect(sessions.first { $0.info.id == "staying" }?.info.cwd == old)
        #expect(plan.session.resumeCommand == "cd \(new) && claude --resume aaaa", "the record given back too")
        #expect(done.contains { $0.contains("memory copied") }, "\(done)")
    }

    @Test func testWithNoOtherSessionThereItsMemoryIsMoved() throws {
        try claudeFixture(shared: false)
        let (plan, done) = try moveSession("moving", to: new)
        #expect(plan.sharedWith.isEmpty)
        #expect(read(project(new) + "aaaa.jsonl") != nil)
        #expect(read(project(new) + "memory/notes.md") == "old notes")
        #expect(read(project(new) + "memory/MEMORY.md") == "- [Notes](notes.md) — old\n- [Same](same.md)\n")
        #expect(!exists(project(old)), "the old project, left with nothing, goes")
        let config = try #require(read(".claude.json"))
        #expect(!config.contains("\"\(old)\""), "\(config)")
        #expect(config.contains("\"\(FolderMove.claudeFolder(new))\""), "\(config)")
        #expect(config.contains("userID"), "the rest kept")
        #expect(done.contains { $0.contains("memory moved") }, "\(done)")
    }

    @Test func testAClashingMemoryIsKeptUnderTheFoldersPrefixAndNotBroughtTwice() throws {
        try claudeFixture(shared: true)
        try write("- [Notes](notes.md) — new\n", project(new) + "memory/MEMORY.md")
        try write("new notes", project(new) + "memory/notes.md")
        try write("same everywhere", project(new) + "memory/same.md")
        let (plan, _) = try moveSession("moving", to: new)
        #expect(plan.memoryRenames == [FolderMove.claudeProjectKey(old) + "/memory/notes.md": "old-notes.md"])
        #expect(read(project(new) + "memory/notes.md") == "new notes", "never overwritten")
        #expect(read(project(new) + "memory/old-notes.md") == "old notes")
        #expect(read(project(new) + "memory/same.md") == "same everywhere")
        #expect(!exists(project(new) + "memory/old-same.md"), "an identical file is dropped")
        let index = try #require(read(project(new) + "memory/MEMORY.md"))
        #expect(index.hasPrefix("- [Notes](notes.md) — new\n"), "\(index)")
        #expect(index.contains("## From \(old)\n\n- [Notes](old-notes.md) — old\n- [Same](same.md)\n"), "\(index)")

        // The other session follows, the last in the old folder: what was
        // copied already isn't brought again.
        _ = try moveSession("staying", to: new)
        let names = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(project(new) + "memory").path).sorted()
        #expect(names == ["MEMORY.md", "notes.md", "old-notes.md", "same.md"])
        let again = try #require(read(project(new) + "memory/MEMORY.md"))
        #expect(again.components(separatedBy: "## From").count == 2, "\(again)")
        #expect(!exists(project(old)))
    }

    @Test func testACodexThreadsRolloutIsGivenTheFolder() throws {
        try store([session("codex", .codex, in: old, resume: "cccc-3")])
        let rollout = ".codex/sessions/2026/11/24/rollout-2026-11-24T10-00-00-cccc-3.jsonl"
        try write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"cccc-3\",\"cwd\":\"\(old)\"}}\n{\"type\":\"turn\"}\n", rollout)
        let (plan, _) = try moveSession("codex", to: new)
        #expect(plan.claudeFrom == nil)
        #expect(plan.codexRollout?.hasSuffix(rollout) == true)
        let text = try #require(read(rollout))
        #expect(text == "{\"payload\":{\"cwd\":\"\(new)\",\"id\":\"cccc-3\"},\"type\":\"session_meta\"}\n{\"type\":\"turn\"}\n", "\(text)")
        #expect(try stored().first?.info.resumeCommand == "cd \(new) && codex resume cccc-3")
    }

    @Test func testAnOpenRouterSessionFileIsGivenTheFolder() throws {
        try store([session("router", .openrouter, in: old, resume: "ffff-6")])
        try write("{\"created\":1,\"cwd\":\"\(old)\",\"id\":\"ffff-6\",\"messages\":[{\"content\":\"hi\",\"role\":\"user\"}],\"model\":\"m\",\"updated\":2}",
                  ".openrouter/sessions/ffff-6.json")
        let log = "{\"id\":\"1\",\"message\":{\"content\":\"hi\",\"role\":\"user\"},\"timestamp\":\"t\"}\n"
        try write(log, ".openrouter/sessions/ffff-6.jsonl")
        let (plan, _) = try moveSession("router", to: new)
        #expect(plan.openRouterSession?.hasSuffix("ffff-6.json") == true)
        let file = try #require(FileManager.default.contents(atPath: home.appendingPathComponent(".openrouter/sessions/ffff-6.json").path))
        let object = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        #expect(object["cwd"] as? String == FolderMove.claudeFolder(new))
        #expect(object["model"] as? String == "m", "the rest kept")
        #expect((object["messages"] as? [Any])?.count == 1)
        #expect(read(".openrouter/sessions/ffff-6.jsonl") == log, "the log has no folder: as it was")
    }

    @Test func testTheSameFolderByAnotherNameIsAMove() throws {
        // universal_ui, renamed isomer, a link to it now: the session's
        // conversation is under the old name's project.
        let isomer = root.appendingPathComponent("work/isomer").path
        let universal = root.appendingPathComponent("work/universal_ui").path
        try FileManager.default.createDirectory(atPath: isomer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: universal, withDestinationPath: isomer)
        try store([session("ui", .claude, in: universal, resume: "aaaa"), session("other", .claude, in: isomer, resume: nil)])
        let oldKey = FolderMove.claudeKey(universal)
        try write("{\"type\":\"user\"}\n", ".claude/projects/\(oldKey)/aaaa.jsonl")

        let (plan, _) = try moveSession("ui", to: isomer)
        #expect(plan.claudeFrom == oldKey)
        #expect(plan.claudeTo == FolderMove.claudeProjectKey(isomer))
        #expect(plan.claudeFrom != plan.claudeTo)
        #expect(read(project(isomer) + "aaaa.jsonl") != nil)
        #expect(!exists(".claude/projects/\(oldKey)/aaaa.jsonl"))
        #expect(try stored().first?.info.cwd == isomer)

        // The other way, to the link: Claude Code sees the same folder, so
        // only the record changes.
        let (back, done) = try moveSession("other", to: universal)
        #expect(back.claudeFrom == back.claudeTo)
        #expect(!done.contains { $0.hasPrefix("Claude") }, "\(done)")
        #expect(try stored().last?.info.cwd == universal)

        // Refused: the folder it's in, by the same name; none; a file.
        let move = FolderMove(target: universal, home: home, data: data)
        #expect(throws: FolderMoveError.sameFolder(universal)) { try move.planSession(id: "other") }
        #expect(throws: FolderMoveError.missing(new + "/gone")) {
            try FolderMove(target: new + "/gone", home: home, data: data).planSession(id: "other")
        }
        try write("x", "file")
        #expect(throws: FolderMoveError.notAFolder(home.appendingPathComponent("file").path)) {
            try FolderMove(target: home.appendingPathComponent("file").path, home: home, data: data).planSession(id: "other")
        }
    }

    @Test func testAPlanChangesNothing() throws {
        try claudeFixture(shared: true)
        try write("- [Notes](notes.md) — new\n", project(new) + "memory/MEMORY.md")
        try write("new notes", project(new) + "memory/notes.md")
        var sessions = try stored()
        sessions.append(session("codex", .codex, in: old, resume: "cccc-3"))
        sessions.append(session("router", .openrouter, in: old, resume: "ffff-6"))
        try store(sessions)
        try write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"cccc-3\",\"cwd\":\"\(old)\"}}\n", ".codex/sessions/2026/11/24/rollout-x-cccc-3.jsonl")
        try write("{\"cwd\":\"\(old)\",\"id\":\"ffff-6\"}", ".openrouter/sessions/ffff-6.json")

        let before = snapshot()
        let move = FolderMove(target: new, home: home, data: data)
        for id in ["moving", "staying", "codex", "router"] {
            let plan = try move.planSession(id: id)
            #expect(!FolderMove.describe(plan).isEmpty)
        }
        let plan = try move.planSession(id: "moving")
        #expect(plan.claudeFiles == ["aaaa.jsonl", "aaaa"])
        #expect(plan.memoryRenames.count == 1)
        #expect(plan.claudeConfigEntry)
        #expect(snapshot() == before)
    }
}
}
