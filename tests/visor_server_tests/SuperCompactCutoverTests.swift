// Super Compact's review and cut-over (VisorServer+SuperCompactCutover):
// HANDOFF.md read and saved (admin-only, within its cap), and the cut-over
// from a job that is done: refused before then, mid-turn, after a discard
// and a second time; the new session in a fresh folder with the old one's
// agent, model, effort and title "(continued)", HANDOFF.md and Claude's
// memory in it, and its first prompt; the old one archived, its unread
// mail moved and its later mail forwarded; and each naming the other.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that writes down what it is told.
@MainActor
private final class CutoverAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String?
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var said: [String] = []
    var stopped = false

    init(resume: String?) {
        resumeID = resume
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { said.append(text) }
    func start() throws {}
    func interrupt() {}
    func stop() { stopped = true }
    func end(within deadline: Duration) async {}
}

private final class CutoverHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: [], defaultModel: "opus") }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { CutoverAgent(resume: resume) }
}

extension ServerTests {
@Suite @MainActor final class SuperCompactCutoverTests {
    private var server: VisorServer!
    private let root: URL
    private let home: URL
    private let savedHome: URL
    private let conversation = "abcdabcd-1111-2222-3333-555555555555"
    private let handoff = "# Handoff: App\n\n## Rules and decisions\n- 2026-11-20: never force-push to main\n"

    init() throws {
        TestPlatform.install()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("visor-cutover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: try #require(realpath(made.path, nil))), isDirectory: true)
        VisorServer.storeRoot = root.appendingPathComponent("data", isDirectory: true)
        VisorServer.secrets = MemorySecrets()
        savedHome = ClaudeSessionFiles.home
        home = root.appendingPathComponent("home", isDirectory: true)
        ClaudeSessionFiles.home = home
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        server.harnesses = AgentHarnesses([CutoverHarness()])
        server.sessionFolders = SessionFolders(sessions: root.appendingPathComponent("Sessions").path)
    }

    isolated deinit {
        server.stop()
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Sessions, jobs and requests

    private var cwd: URL { home.appendingPathComponent("Developer/app", isDirectory: true) }

    private var conversationFile: URL { ClaudeSessionFiles.expectedURL(sessionID: conversation, cwd: cwd.path, home: home) }

    /// A Claude session "App" on Sonnet at high effort, its conversation
    /// on disk, and Claude's memory for its project.
    @discardableResult
    private func session(_ id: String = "s1", title: String = "App") throws -> SessionRecord {
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: conversationFile)
        let info = SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: title, skipPermissions: false, model: "sonnet", effort: "high", created: 0)
        let record = SessionRecord(info: info, process: CutoverAgent(resume: conversation))
        server.sessions.append(record)
        return record
    }

    private func memory(of cwd: String) -> URL {
        VisorServer.memoryProject(cwd).appendingPathComponent("memory", isDirectory: true)
    }

    /// A job of `session`'s in `phase`, kept, with HANDOFF.md and the
    /// ledger written once it is done.
    @discardableResult
    private func job(of session: String = "s1", phase: SuperCompactJob.Phase = .done) throws -> SuperCompactJob {
        let folder = VisorServer.superCompactRoot.appendingPathComponent(session).appendingPathComponent("j-" + session)
        var job = SuperCompactJob(id: "j-" + session, session: session, conversation: conversation, title: "App", source: conversationFile.path,
                                  sourceBytes: 3, folder: folder.path, settings: SuperCompactSettings())
        job.phase = phase
        if phase == .done {
            let url = folder.appendingPathComponent("HANDOFF.md")
            job.handoff = url.path
            job.finished = job.started
            SuperCompactJob.makePrivate(folder)
            try Data(handoff.utf8).write(to: url)
            try Data("## Rules and decisions\n- [2026-11-20] \"Never force-push\" to main\n".utf8)
                .write(to: folder.appendingPathComponent("ledger.md"))
        }
        job.keep()
        return job
    }

    private func rest(_ method: String, _ path: String, body: String = "", bearer: String? = "pw") -> HTTPResponse {
        server.route(HTTPRequest(method: method, path: "/api/sessions/\(path)",
                                 headers: bearer.map { ["authorization": "Bearer " + $0] } ?? [:], body: body))
    }

    private func envelope(_ response: HTTPResponse) throws -> Envelope {
        try #require(Envelope.decode(response.body, defaultType: "reply"))
    }

    private func put(_ text: String, bearer: String? = "pw") -> HTTPResponse {
        var body = Envelope(type: "handoff")
        body.text = text
        return rest("PUT", "s1/super-compact/handoff", body: body.encoded(), bearer: bearer)
    }

    // MARK: The handoff

    @Test func theHandoffIsReadAndSavedForReview() throws {
        try session()
        #expect(rest("GET", "s1/super-compact/handoff").status == 404, "no job yet")
        let job = try job()
        let read = rest("GET", "s1/super-compact/handoff")
        #expect(read.status == 200, "\(read.body)")
        #expect(try envelope(read).text == handoff)
        #expect(try envelope(read).path == job.handoff)

        // Edited: written in place, and the check run again on the edit.
        let edited = "# Handoff: App\n\nNothing about pushing.\n"
        let saved = put(edited)
        #expect(saved.status == 200, "\(saved.body)")
        #expect(try String(contentsOfFile: try #require(job.handoff), encoding: .utf8) == edited)
        let status = try JSONDecoder().decode(SuperCompactJob.self, from: Data(saved.body.utf8))
        #expect(status.warnings.count == 1, "the rule the edit left out: \(status.warnings)")
        #expect(try envelope(rest("GET", "s1/super-compact/handoff")).text == edited)
    }

    @Test func savingTheHandoffIsTheAdminsAndCapped() throws {
        try session()
        try job()
        #expect(put("# Mine", bearer: nil).status == 401)
        #expect(put("# Mine", bearer: "wrong").status == 401)
        let huge = put(String(repeating: "x", count: VisorServer.handoffLimit + 1))
        #expect(huge.status == 413, "\(huge.body)")
        #expect(rest("PUT", "s1/super-compact/handoff", body: "{}").status == 400, "no text")
        #expect(try envelope(rest("GET", "s1/super-compact/handoff")).text == handoff, "nothing refused was written")
    }

    // MARK: The cut-over

    @Test func theCutOverIsRefusedUntilTheJobIsDoneAndWhileATurnRuns() throws {
        let record = try session()
        #expect(rest("POST", "s1/super-compact/cutover").status == 404, "no job")
        try job(phase: .map)
        #expect(rest("POST", "s1/super-compact/cutover").status == 409, "not done")
        try job()
        record.info.busy = true
        let busy = rest("POST", "s1/super-compact/cutover")
        #expect(busy.status == 409)
        #expect(busy.body.contains("middle of a turn"), "\(busy.body)")
        #expect(server.sessions.count == 1, "nothing started")
        #expect(rest("POST", "s1/super-compact/cutover", bearer: nil).status == 401)
    }

    @Test func theCutOverStartsTheNewSessionAndArchivesTheOld() throws {
        let record = try session()
        try job()
        // Claude's memory for the old folder's project.
        let oldMemory = memory(of: cwd.path)
        try FileManager.default.createDirectory(at: oldMemory, withIntermediateDirectories: true)
        try Data("- [Rule](rule.md)\n".utf8).write(to: oldMemory.appendingPathComponent("MEMORY.md"))
        try Data("Never force-push.\n".utf8).write(to: oldMemory.appendingPathComponent("rule.md"))

        let response = rest("POST", "s1/super-compact/cutover")
        #expect(response.status == 200, "\(response.body)")
        let reply = try envelope(response)
        let id = try #require(reply.session)
        let next = try #require(server.session(id))

        // (a) A fresh folder, the same agent, model, effort and permissions.
        #expect(next.info.cwd == server.sessionFolders?.folder(agent: .claude, id: id))
        #expect(next.info.cwd != record.info.cwd)
        #expect(next.info.agent == .claude)
        #expect(next.info.model == "sonnet")
        #expect(next.info.effort == "high")
        #expect(next.info.skipPermissions == false)
        #expect(next.info.title == "App (continued)")
        // (b) HANDOFF.md in its folder.
        let copied = URL(fileURLWithPath: next.info.cwd).appendingPathComponent("HANDOFF.md")
        #expect(try String(contentsOf: copied, encoding: .utf8) == handoff)
        // (c) Claude's memory under its folder's project.
        let newMemory = memory(of: next.info.cwd)
        #expect(newMemory != oldMemory)
        #expect(try String(contentsOf: newMemory.appendingPathComponent("rule.md"), encoding: .utf8) == "Never force-push.\n")
        #expect(FileManager.default.fileExists(atPath: newMemory.appendingPathComponent("MEMORY.md").path))
        #expect(FileManager.default.fileExists(atPath: oldMemory.appendingPathComponent("MEMORY.md").path), "the old one's is left")
        #expect(reply.message?.contains("copied (2 files)") == true, "\(reply.message ?? "")")
        // (d) Its first prompt.
        let agent = try #require(next.process as? CutoverAgent)
        #expect(agent.said == [
            "You're continuing session \"App\" (s1). Read HANDOFF.md in this folder in full, in parts if it's long, "
                + "before anything else, and treat its rules and decisions as the person's own.",
        ])
        // (e) The old one archived, never deleted; its agent stopped.
        #expect(record.info.archived)
        #expect(server.session("s1") === record)
        #expect((record.process as? CutoverAgent)?.stopped == true)
        // (g) Each names the other, on the wire too.
        #expect(record.info.continuedAs == id)
        #expect(next.info.continuedFrom == "s1")
        let listed = try #require(reply.sessions)
        #expect(listed.first { $0.id == "s1" }?.continuedAs == id)
        #expect(listed.first { $0.id == id }?.continuedFrom == "s1")
        // The job says what became of it, and is not cut over twice.
        let status = try JSONDecoder().decode(SuperCompactJob.self, from: Data(rest("GET", "s1/super-compact").body.utf8))
        #expect(status.continuedAs == id)
        let again = rest("POST", "s1/super-compact/cutover")
        #expect(again.status == 409)
        #expect(server.sessions.count == 2)
        #expect(put("# Later").status == 409, "no edits once it is cut over")
    }

    @Test func theInboxIsMovedAndForwarded() throws {
        let record = try session()
        let sender = try session("s9", title: "Reviews")
        try job()
        let from = RelayEndpoint(server: server.id, serverName: server.hostName, session: "s9", sessionName: "Reviews")
        let to = RelayEndpoint(server: server.id, serverName: server.hostName, session: "s1", sessionName: "App")
        record.mailbox.receive(MailMessage(id: "m-read", from: from, to: to, text: "Read already", sent: 1, state: .read, changed: 2))
        record.mailbox.receive(MailMessage(id: "m-unread", from: from, to: to, text: "Still unread", sent: 3, state: .delivered, changed: 3))

        let id = try #require(try envelope(rest("POST", "s1/super-compact/cutover")).session)
        let next = try #require(server.session(id))
        // What waited unread moved, addressed to the new one; what was read stayed.
        #expect(next.mailbox.inbox.map(\.id) == ["m-unread"])
        #expect(next.mailbox.inbox.first?.to.session == id)
        #expect(record.mailbox.inbox.map(\.id) == ["m-read"])
        #expect(next.info.queued.contains { $0.hasPrefix("[Visor: you have 1 unread message") }, "its agent told, once its first turn ends")

        // Mail for the old id goes to the new one from now on, and its
        // sender is told where.
        var ask = Envelope(type: "agent")
        ask.mode = "send"
        ask.session = "s1"
        ask.text = "Where are we?"
        let reply = server.agentReply(ask, caller: sender)
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(reply.text?.contains("forwarded: s1 was carried on as \(id)") == true, "\(reply.text ?? "")")
        #expect(next.mailbox.inbox.map(\.text) == ["Still unread", "Where are we?"])
        #expect(record.mailbox.inbox.count == 1)
        // A message written to it by name or id finds the new one too.
        #expect(server.markedTarget(named: "App", except: sender) === next)
        #expect(server.markedTarget(named: "s1", except: sender) === next)
        #expect(server.forwardedSession("s1") == id)
        #expect(server.forwardedSession("s9") == "s9")
    }

    @Test func aDiscardedHandoffIsNotCutOver() throws {
        try session()
        try job()
        let discarded = rest("DELETE", "s1/super-compact")
        #expect(discarded.status == 200, "\(discarded.body)")
        let status = try JSONDecoder().decode(SuperCompactJob.self, from: Data(discarded.body.utf8))
        #expect(status.discarded != nil)
        #expect(!status.awaitsReview)
        #expect(rest("POST", "s1/super-compact/cutover").status == 409)
        #expect(put("# Mine").status == 409)
        #expect(rest("DELETE", "s1/super-compact").status == 404, "nothing left to cancel or discard")
        #expect(server.sessions.count == 1)
    }

    // MARK: The wire

    @Test func theWireCarriesTheLinksAndTheJob() throws {
        var info = SessionInfo(id: "s1", agent: .claude, cwd: "/tmp", title: "App", created: 1)
        info.continuedAs = "s2"
        info.continuedFrom = "s0"
        #expect(SessionInfo(json: info.json) == info)
        #expect((try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info))) == info)
        #expect(SessionInfo(json: SessionInfo(id: "s1", agent: .claude, cwd: "/", title: "", created: 0).json)?.continuedAs == nil)

        try session()
        var job = try job()
        job.warnings = ["Missing: “Ship 0.64”"]
        job.chunk = 3
        job.chunks = 4
        let parsed = try #require(parseJSON(job.json))
        let status = try #require(SuperCompactStatus(json: parsed))
        #expect(status.id == job.id)
        #expect(status.session == "s1")
        #expect(status.phase == .done)
        #expect(status.chunk == 3 && status.chunks == 4)
        #expect(status.warnings == job.warnings)
        #expect(status.handoff == job.handoff)
        #expect(status.awaitsReview)
        job.discarded = 5
        let discarded = try #require(parseJSON(job.json))
        #expect(SuperCompactStatus(json: discarded)?.discarded == true)
        #expect(SuperCompactStatus(json: status.json) == status)
    }
}
}
