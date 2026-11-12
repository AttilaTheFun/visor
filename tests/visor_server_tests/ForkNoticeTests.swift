// A session forked elsewhere: the chat keeps to the branch it was on (its
// head) and its agent resumes there, and the user is told once. A session
// that has no head yet (from before one was kept) follows the branch
// Claude Code would resume.

import ClaudeTranscript
import MessageCache
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class ForkNoticeTests {
    private var id = ""
    private var file: URL!
    private let cwd = "/tmp/visor_branch_test"
    /// Named as Claude Code would name it for this cwd, so a look at the
    /// expected path finds it, not only a scan.
    private var projectDir: URL { ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd)) }

    init() async throws {
        TestPlatform.install()
        ClaudeSessionFiles.home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-fork-tests-" + UUID().uuidString)
        id = UUID().uuidString.lowercased()
        // A cache of the test's own, never the app's.
        ServerCache.shared = try MessageCache.sqliteInMemory()
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        file = projectDir.appendingPathComponent(id + ".jsonl")
        try lines([
            line("user", "p1", nil, "Remember APPLE"),
            line("assistant", "a1", "p1", "OK-APPLE"),
            line("user", "p2", "a1", "Also BANANA"),
            line("assistant", "a2", "p2", "OK-BANANA"),
        ]).write(to: file, atomically: true, encoding: .utf8)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: ClaudeSessionFiles.home)
    }

    private func line(_ type: String, _ uuid: String, _ parent: String?, _ text: String) -> String {
        let content: Any = type == "assistant" ? [["type": "text", "text": text]] : text
        var o: [String: Any] = ["type": type, "uuid": uuid, "message": ["role": type, "content": content]]
        if let parent { o["parentUuid"] = parent }
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func lines(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    private func append(_ more: [String]) throws {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(lines(more).utf8))
        try handle.close()
    }

    private func record(shownPrompts: [String] = []) -> SessionRecord {
        let info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        return SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: id), shownPrompts: shownPrompts)
    }

    private func texts(_ record: SessionRecord) -> [String] { record.entries.map(\.text) }

    @Test func testForkElsewhereKeepsTheChatOnItsBranchAndResumesThere() async throws {
        let record = record()
        var replaced = 0
        record.onFileReplaced = { replaced += 1 }
        record.followFile()
        await record.waitForFile(past: 0)
        #expect(texts(record) == ["Remember APPLE", "OK-APPLE", "Also BANANA", "OK-BANANA"])
        #expect(record.notice == nil)
        #expect(record.head == "p2")
        #expect(record.leaf == "a2")

        // Another agent resumes from APPLE and writes last. The chat keeps
        // to its branch, says the file went on elsewhere, and its agent is
        // resumed at its own newest message.
        try append([line("user", "p3", "a1", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(texts(record) == ["Remember APPLE", "OK-APPLE", "Also BANANA", "OK-BANANA"])
        #expect(record.info.otherBranch == "Also CHERRY", "offered to the user, by its latest prompt")
        #expect(record.notice == nil)
        #expect(record.shownPrompts == ["p1", "p2"])
        #expect(record.leaf == "a2")
        #expect(record.stored.head == "p2")
        #expect(record.stored.otherBranch == "Also CHERRY")

        // Kept: not offered again, and the agent still resumes here.
        record.keepBranch()
        #expect(record.info.otherBranch == nil)
        #expect(record.wentOnElsewhere)

        // Its agent carries on from there: the conversation is this branch
        // again, and the next resume is Claude Code's own.
        record.notice = nil
        try append([line("user", "p4", "a2", "Also DATE"), line("assistant", "a4", "p4", "OK-DATE")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect((texts(record).suffix(2)) == ["Also DATE", "OK-DATE"])
        #expect(!(texts(record).contains("OK-CHERRY")))
        #expect(!record.wentOnElsewhere)
        #expect(record.info.otherBranch == nil)
        #expect(record.notice == nil)
        #expect(record.head == "p4")
        #expect(record.leaf == "a4")
    }

    @Test func testForkFoundOnResumeFromWhatWasShownBefore() async throws {
        // As after a restart: the archive remembered APPLE and BANANA as
        // shown, and the file has since been forked twice over.
        try append([
            line("user", "p3", "a1", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY"),
            line("user", "p4", "a3", "Also DATE"), line("assistant", "a4", "p4", "OK-DATE"),
        ])
        let record = record(shownPrompts: ["p1", "p2"])
        let generation = record.generation
        record.followFile()
        await record.waitForFile(past: 0)
        #expect(texts(record) == ["Remember APPLE", "OK-APPLE", "Also CHERRY", "OK-CHERRY", "Also DATE", "OK-DATE"])
        #expect((record.notice?.contains("One message shown here")) == true)
        // Clients start again from the new branch: a new generation, and
        // any answer from before it is the whole, marked to reset.
        #expect(record.generation != generation)
        #expect(record.transcriptEnvelope(since: nil).reset == true)
        #expect(record.transcriptEnvelope(since: record.revision).reset == nil)
        #expect(record.stored.notice == record.notice)
        #expect(record.stored.shownPrompts == ["p1", "p3", "p4"])
    }

    @Test func testPreviewIsTheLatestMessage() async throws {
        let record = record()
        record.followFile()
        await record.waitForFile(past: 0)
        // The latest assistant line, trimmed to a line or two.
        #expect(record.info.preview == "OK-BANANA")
        #expect(record.info.updated != nil)
        // A user turn becomes the new preview.
        record.appendUser("What's next?")
        #expect(record.info.preview == "What's next?")
    }

    @Test func testPrimePreviewReadsTheFileNotTheStore() async throws {
        // The store stopped at the user's question; the file has the answer.
        let info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        let stale = [TranscriptEntry(id: "u1", role: .user, text: "Also BANANA")]
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: id), entries: stale)
        primed.primePreview()
        #expect(primed.info.preview == "OK-BANANA")
        // Timed by the file, not by creation.
        #expect((primed.info.updated ?? 0) > 1)
    }

    @Test func testPrimePreviewReplacesAStaleSavedSummary() async throws {
        // An earlier run saved the question; the file has the answer.
        var info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        info.preview = "Also BANANA"
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: id))
        primed.primePreview()
        #expect(primed.info.preview == "OK-BANANA")
    }

    @Test func testServerNotesAreNotPreviews() {
        #expect((SessionRecord.preview(of: TranscriptEntry(id: "n", role: .user, text: "[Visor] The Visor server restarted"))) == nil)
        #expect((SessionRecord.preview(of: TranscriptEntry(id: "u", role: .user, text: "  hello "))) == "hello")
        // A row of tool calls alone says nothing; the last row that spoke serves.
        #expect((SessionRecord.preview(of: TranscriptEntry(id: "t", role: .assistant, text: "", activities: ["Bash: ls"]))) == nil)
        // Paragraph breaks and leading blank lines do not take a line.
        #expect((SessionRecord.preview(of: TranscriptEntry(id: "a", role: .assistant, text: "\n\nDone.\n\n\n- one  \n  \n- two"))) == "Done.\n- one\n- two")
    }

    @Test func testPrimePreviewFillsAnUnopenedSessionFromTheStore() async throws {
        // No file to read (a folder that moved, say): what was kept serves.
        let info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        let entries = [
            TranscriptEntry(id: "u1", role: .user, text: "Hello"),
            TranscriptEntry(id: "a1", role: .assistant, text: "Hi there"),
        ]
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: UUID().uuidString.lowercased()), entries: entries)
        #expect(primed.info.preview == nil)
        primed.primePreview()
        #expect(primed.info.preview == "Hi there")
    }

    @Test func testNothingToSayWhenTheFileMerelyGrew() async throws {
        try append([line("user", "p3", "a2", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY")])
        let record = record(shownPrompts: ["p1", "p2"])
        record.followFile()
        await record.waitForFile(past: 0)
        #expect(texts(record).count == 6)
        #expect(record.notice == nil)
    }

    @Test func testContinuingTheOtherBranchReadsItAndStartsTheChatOver() async throws {
        VisorServer.storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("visor-branch-server-" + UUID().uuidString)
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7993)
        let record = record()
        server.sessions = [record]
        record.followFile()
        await record.waitForFile(past: 0)
        try append([line("user", "p3", "a1", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(record.info.otherBranch == "Also CHERRY")
        let generation = record.generation
        let loads = record.fileLoads

        server.continueOtherBranch(record)
        await record.waitForFile(past: loads)
        #expect(texts(record) == ["Remember APPLE", "OK-APPLE", "Also CHERRY", "OK-CHERRY"])
        #expect(record.info.otherBranch == nil)
        #expect(!record.wentOnElsewhere)
        #expect(record.notice == nil, "moved at the user's word: no fork to tell of")
        #expect(record.head == "p3")
        #expect(record.generation != generation, "clients start over from the branch")
    }
}
}
