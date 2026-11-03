// Sessions backed up to a folder and restored from it, on one server: the
// backup holds each session's conversation (to its last whole line) beside
// the session as a move offers it, and, asked for, a project a move would
// copy; a restore starts a session that is gone again under its own id on
// the same conversation, puts back a conversation file that is missing or
// shorter (the shorter set aside), and leaves one that has gone on since.

import ClaudeTranscript
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class BackupTests: ServerTestCase {
    private var server: VisorServer!
    private var root: URL!
    private var home: URL!
    private var savedHome: URL!
    private let conversation = "aaaaaaaa-2222-3333-4444-555555555555"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-backup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        let made = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: String(cString: try XCTUnwrap(realpath(made.path, nil))), isDirectory: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: 7987)
    }

    override func tearDown() async throws {
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    private let lines = [#"{"type":"user","message":{"content":"Build it"}}"#, #"{"type":"assistant","message":{"content":"Built."}}"#]

    /// A session in a folder of its own, with Claude's file for its
    /// conversation (and half a line being written at its end).
    private func session(_ id: String) throws -> (record: SessionRecord, file: URL) {
        let cwd = home.appendingPathComponent("Developer/app", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let folder = ClaudeSessionFiles.projectsRoot(home: home)
            .appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(conversation + ".jsonl")
        try Data((lines.joined(separator: "\n") + "\n" + #"{"type":"user","#).utf8).write(to: file)
        var info = SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: "App", created: 0)
        info.model = "opus"
        let record = SessionRecord(info: info, process: ClaudeProcess(cwd: cwd.path, skipPermissions: true, resume: conversation))
        server.sessions.append(record)
        return (record, file)
    }

    private var whole: String { lines.joined(separator: "\n") + "\n" }

    func testASessionThatIsGoneIsRestoredUnderItsOwnID() async throws {
        let (_, file) = try session("s1")
        let made = await server.backUp(nil, projects: false, to: nil)
        let backup = try XCTUnwrap(made.backup, made.message ?? "")
        XCTAssertEqual(backup.sessions.map(\.id), ["s1"])
        XCTAssertEqual(backup.sessions.first?.kept, true)
        XCTAssertTrue(backup.path.hasPrefix(VisorServer.backupsFolder.path))
        // The conversation to its last whole line, beside the session.
        let kept = URL(fileURLWithPath: backup.path).appendingPathComponent("s1")
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("conversation-0.jsonl"), encoding: .utf8), whole)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("offer.json").path))
        XCTAssertEqual(VisorServer.keptBackups().map(\.path), [backup.path])

        // The update loses the session and its conversation.
        server.sessions = []
        try FileManager.default.removeItem(at: file)
        let restored = await server.restore(from: URL(fileURLWithPath: backup.path), only: nil)
        XCTAssertEqual(restored.backup?.sessions.first?.outcome, "Restored.", restored.message ?? "")
        let record = try XCTUnwrap(server.session("s1"))
        XCTAssertEqual(record.process.resumeID, conversation)
        XCTAssertEqual(record.info.model, "opus")
        XCTAssertTrue(record.notice?.hasPrefix("Restored from a backup") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), whole)
    }

    func testAConversationThatWentOnStaysAndAShorterOneIsSetAside() async throws {
        let (_, file) = try session("s2")
        let made = await server.backUp(["s2"], projects: false, to: nil)
        let backup = try XCTUnwrap(made.backup)
        let folder = URL(fileURLWithPath: backup.path)

        // Gone on since: left as it is, and so is the session.
        try Data((whole + #"{"type":"user","message":{"content":"And test it"}}"# + "\n").utf8).write(to: file)
        let longer = try String(contentsOf: file, encoding: .utf8)
        let again = await server.restore(from: folder, only: nil)
        XCTAssertEqual(again.backup?.sessions.first?.outcome, "Here already: left as it is.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), longer)

        // Cut short: the kept one put back, the short one set aside.
        try Data(lines[0].utf8).write(to: file)
        let mended = await server.restore(from: folder, only: ["s2"])
        XCTAssertTrue(mended.backup?.sessions.first?.outcome.hasPrefix("Here already; put back") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), whole)
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertTrue(aside.contains { $0.hasPrefix(conversation + ".jsonl.before-restore-") })
    }

    func testASessionWithNoConversationIsSaidNotBackedUp() async throws {
        server.sessions = [SessionRecord(info: SessionInfo(id: "new", agent: .claude, cwd: "/tmp", title: "New", created: 0),
                                         process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil))]
        let made = await server.backUp(nil, projects: false, to: nil)
        let backup = try XCTUnwrap(made.backup)
        XCTAssertEqual(backup.sessions.first?.kept, false)
        XCTAssertEqual(backup.sessions.first?.outcome, "Not backed up: it has no conversation yet.")
    }

    /// On the wire: a backup and the backups kept, the sessions a request
    /// is about and whether projects come too.
    func testABackupOnTheWire() throws {
        var e = Envelope(type: "backup")
        e.backup = SessionBackup(path: "/b/1", created: 5, from: "Mac", sessions: [SessionBackupItem(id: "s", title: "App", outcome: "Restored.", kept: true)],
                                 size: 9)
        e.backups = [e.backup!]
        e.sessionIDs = ["s"]
        e.projects = true
        let back = try XCTUnwrap(Envelope.decode(e.encoded(), defaultType: "reply"))
        XCTAssertEqual(back.backup, e.backup)
        XCTAssertEqual(back.backups, e.backups)
        XCTAssertEqual(back.sessionIDs, ["s"])
        XCTAssertEqual(back.projects, true)
    }

    func testABackupGoesIntoAFolderOfItsOwn() async throws {
        _ = try session("s3")
        let taken = root.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: taken.appendingPathComponent("other"))
        let refused = await server.backUp(nil, projects: false, to: taken)
        XCTAssertEqual(refused.type, "error")
    }

    /// Asked for, a project a move would copy (no remote) is kept packed,
    /// and unpacked where it was when it is gone.
    func testAProjectWithNoRemoteComesBackWhenAsked() async throws {
        _ = try session("s4")
        let project = home.appendingPathComponent("Developer/app")
        try Data("let a = 1\n".utf8).write(to: project.appendingPathComponent("main.swift"))
        _ = await ProjectSurvey.git(["init", "-q"], in: project.path)
        _ = await ProjectSurvey.git(["add", "."], in: project.path)
        _ = await ProjectSurvey.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "First"], in: project.path)
        let made = await server.backUp(["s4"], projects: true, to: nil)
        let backup = try XCTUnwrap(made.backup)
        XCTAssertEqual(backup.sessions.first?.outcome, "Backed up.")

        server.sessions = []
        try FileManager.default.removeItem(at: project)
        let restored = await server.restore(from: URL(fileURLWithPath: backup.path), only: nil)
        XCTAssertEqual(restored.backup?.sessions.first?.outcome, "Restored.", restored.message ?? "")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("main.swift"), encoding: .utf8), "let a = 1\n")
    }
}
