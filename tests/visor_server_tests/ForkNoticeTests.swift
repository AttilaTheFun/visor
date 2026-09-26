// A session forked elsewhere: the chat follows the branch Claude Code
// would resume, and the user is told once.

import ClaudeTranscript
import MessageCache
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class ForkNoticeTests: XCTestCase {
    private var id = ""
    private var file: URL!
    private let cwd = "/tmp/visor_branch_test"
    /// Named as Claude Code would name it for this cwd, so a look at the
    /// expected path finds it, not only a scan.
    private var projectDir: URL { ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd)) }

    override func setUp() async throws {
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

    override func tearDown() async throws {
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

    func testForkWhileIdleMovesTheChatAndSaysSo() async throws {
        let record = record()
        var replaced = 0
        record.onFileReplaced = { replaced += 1 }
        record.followFile()
        await record.waitForFile(past: 0)
        XCTAssertEqual(texts(record), ["Remember APPLE", "OK-APPLE", "Also BANANA", "OK-BANANA"])
        XCTAssertNil(record.notice)
        XCTAssertEqual(record.shownPrompts, ["p1", "p2"])

        // Another agent resumes from APPLE and writes last: BANANA is left behind.
        try append([line("user", "p3", "a1", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(texts(record), ["Remember APPLE", "OK-APPLE", "Also CHERRY", "OK-CHERRY"])
        XCTAssertEqual(record.notice?.hasPrefix("Another Claude Code resumed this session"), true)
        XCTAssertEqual(record.notice?.contains("One message shown here"), true)
        XCTAssertEqual(record.shownPrompts, ["p1", "p3"])
        XCTAssertGreaterThanOrEqual(replaced, 1)

        // Someone continuing the conversation is not a fork: no new notice.
        record.notice = nil
        try append([line("user", "p4", "a3", "Also DATE"), line("assistant", "a4", "p4", "OK-DATE")])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(texts(record).last, "OK-DATE")
        XCTAssertNil(record.notice)
        XCTAssertEqual(record.shownPrompts, ["p1", "p3", "p4"])
    }

    func testForkFoundOnResumeFromWhatWasShownBefore() async throws {
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
        XCTAssertEqual(texts(record), ["Remember APPLE", "OK-APPLE", "Also CHERRY", "OK-CHERRY", "Also DATE", "OK-DATE"])
        XCTAssertEqual(record.notice?.contains("One message shown here"), true)
        // Clients start again from the new branch: a new generation, and
        // any answer from before it is the whole, marked to reset.
        XCTAssertNotEqual(record.generation, generation)
        XCTAssertEqual(record.transcriptEnvelope(since: nil).reset, true)
        XCTAssertNil(record.transcriptEnvelope(since: record.revision).reset)
        XCTAssertEqual(record.stored.notice, record.notice)
        XCTAssertEqual(record.stored.shownPrompts, ["p1", "p3", "p4"])
    }

    func testPreviewIsTheLatestMessage() async throws {
        let record = record()
        record.followFile()
        await record.waitForFile(past: 0)
        // The latest assistant line, trimmed to a line or two.
        XCTAssertEqual(record.info.preview, "OK-BANANA")
        XCTAssertNotNil(record.info.updated)
        // A user turn becomes the new preview.
        _ = record.appendUser("What's next?")
        XCTAssertEqual(record.info.preview, "What's next?")
    }

    func testPrimePreviewReadsTheFileNotTheStore() async throws {
        // The store stopped at the user's question; the file has the answer.
        let info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        let stale = [TranscriptEntry(id: "u1", role: .user, text: "Also BANANA")]
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: id), entries: stale)
        primed.primePreview()
        XCTAssertEqual(primed.info.preview, "OK-BANANA")
        // Timed by the file, not by creation.
        XCTAssertGreaterThan(primed.info.updated ?? 0, 1)
    }

    func testPrimePreviewReplacesAStaleSavedSummary() async throws {
        // An earlier run saved the question; the file has the answer.
        var info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        info.preview = "Also BANANA"
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: id))
        primed.primePreview()
        XCTAssertEqual(primed.info.preview, "OK-BANANA")
    }

    func testServerNotesAreNotPreviews() {
        XCTAssertNil(SessionRecord.preview(of: TranscriptEntry(id: "n", role: .user, text: "[Visor] The Visor server restarted")))
        XCTAssertEqual(SessionRecord.preview(of: TranscriptEntry(id: "u", role: .user, text: "  hello ")), "hello")
        // A row of tool calls alone says nothing; the last row that spoke serves.
        XCTAssertNil(SessionRecord.preview(of: TranscriptEntry(id: "t", role: .assistant, text: "", activities: ["Bash: ls"])))
        // Paragraph breaks and leading blank lines do not take a line.
        XCTAssertEqual(SessionRecord.preview(of: TranscriptEntry(id: "a", role: .assistant, text: "\n\nDone.\n\n\n- one  \n  \n- two")), "Done.\n- one\n- two")
    }

    func testPrimePreviewFillsAnUnopenedSessionFromTheStore() async throws {
        // No file to read (a folder that moved, say): what was kept serves.
        let info = SessionInfo(id: "s", agent: .claude, cwd: cwd, title: "t", created: 0)
        let entries = [
            TranscriptEntry(id: "u1", role: .user, text: "Hello"),
            TranscriptEntry(id: "a1", role: .assistant, text: "Hi there"),
        ]
        let primed = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd, skipPermissions: true, resume: UUID().uuidString.lowercased()), entries: entries)
        XCTAssertNil(primed.info.preview)
        primed.primePreview()
        XCTAssertEqual(primed.info.preview, "Hi there")
    }

    func testNothingToSayWhenTheFileMerelyGrew() async throws {
        try append([line("user", "p3", "a2", "Also CHERRY"), line("assistant", "a3", "p3", "OK-CHERRY")])
        let record = record(shownPrompts: ["p1", "p2"])
        record.followFile()
        await record.waitForFile(past: 0)
        XCTAssertEqual(texts(record).count, 6)
        XCTAssertNil(record.notice)
    }
}
