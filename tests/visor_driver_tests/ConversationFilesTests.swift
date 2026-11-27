// A moved session's conversation as the driver hands it to the runner's
// wrapper: the conversation, what its subagents kept beside it file by
// file, and the project's memory (where Claude Code keeps it here, a link
// followed), each placed under Claude's folder for the folder the session
// will work in there, the memory under the project Claude Code keeps that
// folder's memory under.

import ClaudeTranscript
@testable import VisorDriver
import Foundation
import Testing

// One at a time: each sets the one home folder Claude's files are under.
@Suite(.serialized) final class ConversationFilesTests {
    private var savedHome: URL!
    private var home: URL!

    init() async throws {
        savedHome = ClaudeSessionFiles.home
        home = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-files-\(UUID().uuidString)", isDirectory: true)
        ClaudeSessionFiles.home = home
    }

    deinit {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ text: String) throws {
        let file = home.appendingPathComponent(".claude/projects/-Users-logan-Developer/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func testTheConversationItsSubagentsAndTheMemoryArePlacedForTheRunnersFolder() throws {
        try write("c-123.jsonl", "{}\n")
        try write("c-123/subagents/agent-a.jsonl", "{}\n")
        try write("memory/MEMORY.md", "- a memory\n")
        try write("memory/fact.md", "a fact\n")
        try write("c-999.jsonl", "another conversation\n")
        let files = ConversationFiles.of(resume: "c-123", cwd: "/Users/logan/Developer", for: "/Volumes/Sessions/Claude/s7")
        let key = ClaudeSessionFiles.projectDirectoryName(for: "/Volumes/Sessions/Claude/s7")
        #expect((files.map(\.place).sorted()) == [
            "projects/\(key)/c-123.jsonl",
            "projects/\(key)/c-123/subagents/agent-a.jsonl",
            "projects/\(key)/memory/MEMORY.md",
            "projects/\(key)/memory/fact.md",
        ])
        #expect(ConversationFiles.of(resume: "nothing", cwd: "/Users/logan/Developer", for: "/w").isEmpty)
    }

    private func write(at file: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func project(_ cwd: String) -> URL {
        ClaudeSessionFiles.projectsRoot(home: home).appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
    }

    /// Move to Container: a conversation begun in a folder of a repository,
    /// kept under that folder's project, whose memory is under the
    /// repository's (as Claude Code keeps it), goes down with that memory.
    @Test func testTheMemoryOfARepositorysProjectGoesWithAConversationInOneOfItsFolders() throws {
        let top = home.appendingPathComponent("Developer/app", isDirectory: true)
        try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let inside = top.appendingPathComponent("Sources", isDirectory: true).path
        try write(at: project(inside).appendingPathComponent("c-1.jsonl"), "{}\n")
        try write(at: project(top.path).appendingPathComponent("memory/MEMORY.md"), "- the repository's\n")
        let files = ConversationFiles.of(resume: "c-1", cwd: inside, for: "/Volumes/Sessions/Claude/s8")
        let key = ClaudeSessionFiles.projectDirectoryName(for: "/Volumes/Sessions/Claude/s8")
        #expect(files.map(\.place).sorted() == ["projects/\(key)/c-1.jsonl", "projects/\(key)/memory/MEMORY.md"])
    }

    /// A memory that is a link (Overcast's, 26 Nov 2026) goes down as the
    /// files of the folder it leads to.
    @Test func testAMemoryThatIsALinkGoesAsItsFolder() throws {
        let cwd = home.appendingPathComponent("Developer/overcast", isDirectory: true).path
        try write(at: project(cwd).appendingPathComponent("c-2.jsonl"), "{}\n")
        let target = ClaudeSessionFiles.projectsRoot(home: home).appendingPathComponent("-elsewhere/memory", isDirectory: true)
        try write(at: target.appendingPathComponent("MEMORY.md"), "- linked\n")
        try FileManager.default.createSymbolicLink(at: project(cwd).appendingPathComponent("memory"), withDestinationURL: target)
        let files = ConversationFiles.of(resume: "c-2", cwd: cwd, for: "/Volumes/Sessions/Claude/s9")
        let key = ClaudeSessionFiles.projectDirectoryName(for: "/Volumes/Sessions/Claude/s9")
        #expect(files.map(\.place).sorted() == ["projects/\(key)/c-2.jsonl", "projects/\(key)/memory/MEMORY.md"])
        let memory = try #require(files.first { $0.place.hasSuffix("MEMORY.md") })
        #expect((try String(contentsOf: memory.url, encoding: .utf8)) == "- linked\n")
    }

    /// A memory leading out of Claude's projects folder isn't sent; nor is
    /// a link inside one, whatever it leads to (NCH, #562).
    @Test func testNoLinkOutOfClaudesProjectsIsSent() throws {
        let secret = home.appendingPathComponent("secret.txt")
        try write(at: secret, "a secret key\n")
        let out = home.appendingPathComponent("Developer/out", isDirectory: true).path
        try write(at: project(out).appendingPathComponent("c-3.jsonl"), "{}\n")
        let keys = home.appendingPathComponent(".ssh", isDirectory: true)
        try write(at: keys.appendingPathComponent("id_ed25519"), "a secret key\n")
        try FileManager.default.createSymbolicLink(at: project(out).appendingPathComponent("memory"), withDestinationURL: keys)
        let key = ClaudeSessionFiles.projectDirectoryName(for: "/Volumes/Sessions/Claude/s10")
        var said: [String] = []
        let sent = ConversationFiles.of(resume: "c-3", cwd: out, for: "/Volumes/Sessions/Claude/s10", log: { said.append($0) })
        #expect(sent.map(\.place) == ["projects/\(key)/c-3.jsonl"])
        #expect(said.count == 1 && said.allSatisfy { $0.contains("leads out of") }, "\(said)")
        let inside = home.appendingPathComponent("Developer/in", isDirectory: true).path
        try write(at: project(inside).appendingPathComponent("c-4.jsonl"), "{}\n")
        try write(at: project(inside).appendingPathComponent("memory/MEMORY.md"), "- [Key](key.md)\n")
        try FileManager.default.createSymbolicLink(at: project(inside).appendingPathComponent("memory/key.md"), withDestinationURL: secret)
        let files = ConversationFiles.of(resume: "c-4", cwd: inside, for: "/Volumes/Sessions/Claude/s10")
        #expect(files.map(\.place).sorted() == ["projects/\(key)/c-4.jsonl", "projects/\(key)/memory/MEMORY.md"])
    }
}
