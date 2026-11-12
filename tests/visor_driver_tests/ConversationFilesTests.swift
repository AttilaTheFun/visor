// A moved session's conversation as the driver hands it to the runner's
// wrapper: the conversation, what its subagents kept beside it file by
// file, and the project's memory, each placed under Claude's folder for the
// folder the session will work in there.

import ClaudeTranscript
@testable import VisorDriver
import Foundation
import XCTest

final class ConversationFilesTests: XCTestCase {
    private var savedHome: URL!
    private var home: URL!

    override func setUp() async throws {
        savedHome = ClaudeSessionFiles.home
        home = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-files-\(UUID().uuidString)", isDirectory: true)
        ClaudeSessionFiles.home = home
    }

    override func tearDown() async throws {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ text: String) throws {
        let file = home.appendingPathComponent(".claude/projects/-Users-logan-Developer/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testTheConversationItsSubagentsAndTheMemoryArePlacedForTheRunnersFolder() throws {
        try write("c-123.jsonl", "{}\n")
        try write("c-123/subagents/agent-a.jsonl", "{}\n")
        try write("memory/MEMORY.md", "- a memory\n")
        try write("memory/fact.md", "a fact\n")
        try write("c-999.jsonl", "another conversation\n")
        let files = ConversationFiles.of(resume: "c-123", cwd: "/Users/logan/Developer", for: "/Volumes/Sessions/Claude/s7")
        let key = ClaudeSessionFiles.projectDirectoryName(for: "/Volumes/Sessions/Claude/s7")
        XCTAssertEqual(files.map(\.place).sorted(), [
            "projects/\(key)/c-123.jsonl",
            "projects/\(key)/c-123/subagents/agent-a.jsonl",
            "projects/\(key)/memory/MEMORY.md",
            "projects/\(key)/memory/fact.md",
        ])
        XCTAssertTrue(ConversationFiles.of(resume: "nothing", cwd: "/Users/logan/Developer", for: "/w").isEmpty)
    }
}
