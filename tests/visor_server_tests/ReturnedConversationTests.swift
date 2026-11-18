// A handed-back session's conversation as its runner returns it
// (ReturnedConversationIntake), held to #444's rules for a move here: only
// that conversation's own places, under the runner's key and session id,
// re-keyed for the folder the session moves back to; staged, and put in
// place only once whole; refused past a move's caps or the room here with
// nothing written; no link here followed; a shorter file here set aside,
// a longer one left.

import ClaudeTranscript
import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite final class ReturnedConversationTests {
    private let root: URL
    private let claude: URL
    private let session = "0b6c2d1e-8f3a-4c5b-9d7e-1a2b3c4d5e6f"
    private let runnerFolder = "/Volumes/Sessions/Claude/4d9a6f1e-0c2b-4e8a-9f3d-7b6a5c4d3e2f"
    private let here = "/Users/a/Developer/visor_app"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("returned-conversation-" + UUID().uuidString, isDirectory: true)
        claude = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var runnerKey: String { ReturnedConversationIntake.runnerKey(for: runnerFolder) }
    private var hostKey: String { ClaudeSessionFiles.projectDirectoryName(for: here) }
    private var project: URL { claude.appendingPathComponent("projects/" + hostKey, isDirectory: true) }

    private func target(_ limits: HandBackLimits = HandBackLimits(), free: Int? = nil) -> HandBackTarget {
        HandBackTarget(session: "s1", agent: "a1", cwd: here, claudeFolder: claude, key: hostKey, limits: limits, free: free)
    }

    private func intake(_ limits: HandBackLimits = HandBackLimits(), free: Int? = nil) throws -> ReturnedConversationIntake {
        try ReturnedConversationIntake(target: target(limits, free: free), harness: "claude", workingDirectory: runnerFolder, sessionID: session)
    }

    /// The runner's place for `rest` under its project.
    private func place(_ rest: String) -> String { "projects/\(runnerKey)/\(rest)" }

    private func send(_ taking: ReturnedConversationIntake, _ rest: String, _ text: String) throws {
        try taking.take(place: place(rest), data: Data(text.utf8), last: true)
    }

    private func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// Every path under `folder`, relative, sorted.
    private func everything(under folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
    }

    @Test func theFilesArePutUnderTheKeyOfTheFolderItMovesBackTo() throws {
        #expect(runnerKey == "-Volumes-Sessions-Claude-4d9a6f1e-0c2b-4e8a-9f3d-7b6a5c4d3e2f")
        let taking = try intake()
        try send(taking, session + ".jsonl", "{\"turn\":1}\n{\"turn\":2}\n")
        try taking.take(place: place(session + "/subagents/agent-a.jsonl"), data: Data("{}".utf8), last: false)
        try taking.take(place: place(session + "/subagents/agent-a.jsonl"), data: Data("\n".utf8), last: true)
        try send(taking, "memory/MEMORY.md", "- the word is heliotrope\n")
        let staged = try taking.finish()
        #expect(staged.files == [session + ".jsonl", session + "/subagents/agent-a.jsonl", "memory/MEMORY.md"])
        let placement = try staged.place(stamp: "20261118-120000")
        #expect(placement.placed.count == 3 && placement.replaced.isEmpty && placement.kept.isEmpty)
        #expect(placement.conversation == session, "claude --resume finds it in the folder it moves back to")
        #expect(text(project.appendingPathComponent(session + ".jsonl")) == "{\"turn\":1}\n{\"turn\":2}\n")
        #expect(text(project.appendingPathComponent(session + "/subagents/agent-a.jsonl")) == "{}\n")
        #expect(text(project.appendingPathComponent("memory/MEMORY.md")) == "- the word is heliotrope\n")
        #expect(everything(under: claude.appendingPathComponent("projects")).allSatisfy { $0.hasPrefix(hostKey) },
                "nothing under the runner's key, nor anywhere else")
        #expect(!everything(under: project).contains { $0.contains(".visor-handback-") }, "the staging folder gone")
    }

    @Test func aPlaceOutsideTheConversationIsRefused() throws {
        let other = "9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b"
        let refused = [
            "/etc/passwd",
            "/" + place(session + ".jsonl"),
            place("../" + session + ".jsonl"),
            place(session + "/../../../settings.json"),
            place("memory/../../x"),
            place("memory//MEMORY.md"),
            place("./" + session + ".jsonl"),
            place(session),
            place("memory"),
            place(other + ".jsonl"),
            place(other + "/subagents/a.jsonl"),
            place("settings.json"),
            place(session + ".jsonl/x"),
            "projects/-Users-a-elsewhere/\(session).jsonl",
            "projects/\(runnerKey)",
            "settings.json",
            "../projects/\(runnerKey)/\(session).jsonl",
            "projects/\(runnerKey)/\(session).jsonl\0",
            "",
        ]
        for wrong in refused {
            let taking = try intake()
            #expect(taking.relative(of: wrong) == nil, "\(wrong)")
            #expect(throws: ReturnedConversationIntake.Refusal.self, "\(wrong)") {
                try taking.take(place: wrong, data: Data("x".utf8), last: true)
            }
            taking.discard()
        }
        #expect(!FileManager.default.fileExists(atPath: claude.path), "nothing written, not even a folder")
    }

    @Test func aHeaderOutsideWhatAHandBackReturnsIsRefused() throws {
        #expect(throws: ReturnedConversationIntake.Refusal.self, "Codex's") {
            try ReturnedConversationIntake(target: target(), harness: "codex", workingDirectory: runnerFolder, sessionID: session)
        }
        #expect(throws: ReturnedConversationIntake.Refusal.self, "a session id that isn't Claude's") {
            try ReturnedConversationIntake(target: target(), harness: "claude", workingDirectory: runnerFolder, sessionID: "../x")
        }
        #expect(throws: ReturnedConversationIntake.Refusal.self, "a working directory that isn't a full path") {
            try ReturnedConversationIntake(target: target(), harness: "claude", workingDirectory: "/Volumes/../etc", sessionID: session)
        }
        // A harness that never said its session: the header alone.
        let none = try ReturnedConversationIntake(target: target(), harness: "", workingDirectory: runnerFolder, sessionID: "")
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try none.take(place: "projects/x/.jsonl", data: Data(), last: true) }
        #expect(try none.finish().place(stamp: "s").conversation == nil)
    }

    @Test func piecesOfTwoFilesInterleavedOrAFileUnendedOrSentTwiceAreRefused() throws {
        let interleaved = try intake()
        try interleaved.take(place: place(session + ".jsonl"), data: Data("a".utf8), last: false)
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try self.send(interleaved, "memory/a.md", "b") }
        interleaved.discard()

        let unended = try intake()
        try unended.take(place: place(session + ".jsonl"), data: Data("a".utf8), last: false)
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try unended.finish() }
        unended.discard()

        let twice = try intake()
        try send(twice, "memory/a.md", "a")
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try self.send(twice, "memory/a.md", "b") }
        twice.discard()
        #expect(!FileManager.default.fileExists(atPath: claude.path), "nothing written")
    }

    /// Past each cap, and past the room here: refused, nothing written.
    @Test func pastAMovesCapsOrTheRoomHereNothingIsWritten() throws {
        func refusal(_ limits: HandBackLimits, free: Int? = nil, _ files: [(String, Int)]) throws -> ReturnedConversationIntake.Refusal? {
            let taking = try intake(limits, free: free)
            defer { taking.discard() }
            do {
                for (rest, size) in files { try taking.take(place: place(rest), data: Data(repeating: 0x61, count: size), last: true) }
                _ = try taking.finish()
                return nil
            } catch let refusal as ReturnedConversationIntake.Refusal {
                return refusal
            }
        }
        let small = HandBackLimits(fileBytes: 100, totalBytes: 150, files: 3, freeMargin: 10)
        #expect(try refusal(small, [(session + ".jsonl", 100), ("memory/a.md", 50)]) == nil, "within every cap")
        #expect(try refusal(small, [(session + ".jsonl", 101)])?.kind == .tooLarge, "a file past its cap")
        #expect(try refusal(small, [(session + ".jsonl", 100), ("memory/a.md", 51)])?.kind == .tooLarge, "all of them past theirs")
        #expect(try refusal(small, [("memory/a", 1), ("memory/b", 1), ("memory/c", 1), ("memory/d", 1)])?.kind == .tooLarge, "too many")
        #expect(try refusal(small, free: 100, [(session + ".jsonl", 91)])?.kind == .noRoom, "no room for it with the margin")
        #expect(try refusal(small, free: 100, [(session + ".jsonl", 90)]) == nil)
        #expect(!FileManager.default.fileExists(atPath: claude.path), "nothing left behind, not even a folder")
        // The defaults are a move's.
        let defaults = HandBackLimits()
        #expect(defaults.fileBytes == VisorServer.migrationFileCap && defaults.totalBytes == VisorServer.migrationTotalCap)
        #expect(defaults.files == VisorServer.unpackEntryCap && defaults.freeMargin == VisorServer.migrationFreeMargin)
    }

    @Test func aShorterFileHereIsSetAsideAndALongerOneLeft() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("memory"), withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent(session + ".jsonl")
        let memory = project.appendingPathComponent("memory/MEMORY.md")
        try Data("{\"turn\":1}\n".utf8).write(to: transcript)
        try Data("- a longer memory than the runner's\n".utf8).write(to: memory)
        let taking = try intake()
        try send(taking, session + ".jsonl", "{\"turn\":1}\n{\"turn\":2}\n")
        try send(taking, "memory/MEMORY.md", "- short\n")
        let placement = try taking.finish().place(stamp: "20261118-120000")
        #expect(placement.replaced == [session + ".jsonl"] && placement.kept == ["memory/MEMORY.md"])
        #expect(text(transcript) == "{\"turn\":1}\n{\"turn\":2}\n")
        #expect(text(project.appendingPathComponent(session + ".jsonl.before-handback-20261118-120000")) == "{\"turn\":1}\n", "set aside, not removed")
        #expect(text(memory) == "- a longer memory than the runner's\n", "left as it was")
        #expect(!everything(under: project).contains { $0.contains("MEMORY.md.before-handback") })
    }

    @Test func noLinkHereIsFollowed() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let projects = claude.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        // The project's folder a link: refused before anything is staged.
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: outside)
        let linkedProject = try intake()
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try self.send(linkedProject, self.session + ".jsonl", "{}\n") }
        linkedProject.discard()
        #expect(everything(under: outside).isEmpty)
        try FileManager.default.removeItem(at: project)

        // Its memory a link, and a transcript here that is one: refused
        // when it is put in place, before anything is moved.
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("memory"), withDestinationURL: outside)
        let linkedMemory = try intake()
        try send(linkedMemory, session + ".jsonl", "{}\n")
        try send(linkedMemory, "memory/MEMORY.md", "- x\n")
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try linkedMemory.finish().place(stamp: "s") }
        #expect(everything(under: outside).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(session + ".jsonl").path), "nothing moved")
        #expect(everything(under: project) == ["memory"], "the staging folder gone")

        try FileManager.default.removeItem(at: project.appendingPathComponent("memory"))
        let elsewhere = outside.appendingPathComponent("transcript.jsonl")
        try Data("x".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(session + ".jsonl"), withDestinationURL: elsewhere)
        let linkedTranscript = try intake()
        try send(linkedTranscript, session + ".jsonl", "{\"turn\":1}\n")
        #expect(throws: ReturnedConversationIntake.Refusal.self) { try linkedTranscript.finish().place(stamp: "s") }
        #expect(text(elsewhere) == "x", "what it leads to untouched")
    }
}
}
