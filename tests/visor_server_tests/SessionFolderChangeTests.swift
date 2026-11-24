// A session given another working directory from its inspector (`POST
// /api/sessions/<id>/folder`, VisorServer+SessionFolder): refused, with
// nothing changed, mid-turn, for a session whose agent runs elsewhere, for
// one archived, during an update's watch and for a folder it can't be
// given; otherwise its agent ended, its conversation moved to the new
// folder's project, its record given the folder (kept in sessions.json)
// and its agent made again there on the same conversation. A move whose
// files can't be moved leaves it where it was, its agent resumed there.

import ClaudeTranscript
import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// The agents a harness made: where, and on which conversation.
@MainActor
private final class MadeAgents {
    var made: [(agent: FolderAgent, cwd: String, resume: String?)] = []
}

@MainActor
private final class FolderAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    let resumeID: String?
    var resumeCommand: String? { nil }
    var processID: Int32? { started ? 4242 : nil }
    var started = false
    var ended = false

    init(resume: String?) {
        resumeID = resume
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { started = true }
    func start() throws { started = true }
    func interrupt() {}
    func stop() { ended = true }
    func end(within deadline: Duration) async { ended = true }
}

private final class FolderHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"
    let agents: MadeAgents

    init(_ agents: MadeAgents) { self.agents = agents }

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: []) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        let agent = FolderAgent(resume: resume)
        agents.made.append((agent, cwd, resume))
        return agent
    }
}

extension ServerTests {
@Suite @MainActor final class SessionFolderChangeTests {
    private var server: VisorServer!
    private let agents = MadeAgents()
    private let root: URL
    private let savedHome = ClaudeSessionFiles.home
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var old: String { root.appendingPathComponent("work/old").path }
    private var new: String { root.appendingPathComponent("work/new").path }

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-folder-" + UUID().uuidString, isDirectory: true)
        for folder in [root.appendingPathComponent("data").path, home.path, old, new] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        VisorServer.storeRoot = root.appendingPathComponent("data", isDirectory: true)
        VisorServer.secrets = MemorySecrets()
        ClaudeSessionFiles.home = home
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        server.harnesses = AgentHarnesses([FolderHarness(agents)])
    }

    isolated deinit {
        server.stop()
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    /// A Claude Code session in the old folder on the conversation
    /// `conv-1`, its transcript in the old folder's project.
    private func session() throws -> SessionRecord {
        let info = SessionInfo(id: "S", agent: .claude, cwd: old, title: "Isomer", resumeCommand: "cd \(old) && claude --resume conv-1", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: "conv-1"))
        server.sessions = [record]
        try write("{\"type\":\"user\"}\n", project(old) + "conv-1.jsonl")
        return record
    }

    private func project(_ folder: String) -> String { ".claude/projects/" + FolderMove.claudeProjectKey(folder) + "/" }

    private func write(_ text: String, _ path: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

    private func post(_ id: String, path: String) async -> HTTPResponse {
        let body = JSONValue.object(["path": .string(path)]).encoded()
        let request = HTTPRequest(method: "POST", path: "/api/sessions/\(id)/folder", headers: ["authorization": "Bearer pw"], body: body, trusted: false)
        return await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    /// Nothing changed: its folder, its agent (none made since), its
    /// conversation where it was.
    private func expectUnmoved(_ record: SessionRecord, agentsBefore: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(record.info.cwd == old, sourceLocation: sourceLocation)
        #expect(agents.made.count == agentsBefore, "no agent made: \(agents.made.map(\.cwd))", sourceLocation: sourceLocation)
        #expect(exists(project(old) + "conv-1.jsonl"), sourceLocation: sourceLocation)
    }

    @Test func midTurnItIsRefusedUntilTheTurnEnds() async throws {
        let record = try session()
        let before = agents.made.count
        record.info.busy = true
        let answer = await post("S", path: new)
        #expect(answer.status == 409)
        #expect(answer.body.contains("wait for it to finish"), "\(answer.body)")
        expectUnmoved(record, agentsBefore: before)
        #expect(!(agents.made.last?.agent.ended ?? true), "its agent left working")
    }

    @Test func aSessionWhoseAgentRunsElsewhereIsRefused() async throws {
        let record = try session()
        let before = agents.made.count
        record.driven = true
        let said = await server.moveFolder(record, to: new)
        #expect(said?.contains("runs elsewhere") == true, "\(said ?? "moved")")
        expectUnmoved(record, agentsBefore: before)
    }

    @Test func anArchivedSessionIsRefused() async throws {
        let record = try session()
        server.archive(record)
        let before = agents.made.count
        let said = await server.moveFolder(record, to: new)
        #expect(said?.contains("is archived") == true, "\(said ?? "moved")")
        expectUnmoved(record, agentsBefore: before)
    }

    @Test func duringAnUpdatesWatchItIsRefused() async throws {
        let record = try session()
        let before = agents.made.count
        // This process stands for a live watcher.
        let now = Int(Date().timeIntervalSince1970)
        try Data("\(ProcessInfo.processInfo.processIdentifier) \(now - 30)\n".utf8).write(to: RelaunchWatchLock.url)
        defer { try? FileManager.default.removeItem(at: RelaunchWatchLock.url) }
        let answer = await post("S", path: new)
        #expect(answer.status == 409)
        #expect(answer.body.contains("An update is still being watched"), "\(answer.body)")
        expectUnmoved(record, agentsBefore: before)
    }

    @Test func aFolderItCantBeGivenIsRefusedInWords() async throws {
        let record = try session()
        let before = agents.made.count
        let file = root.appendingPathComponent("work/notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        let cases = [("work/new", "is not a full path"), (new + "-missing", "There is no"), (file.path, "is a file, not a folder"),
                     (old, "is in \(old) already")]
        for (path, words) in cases {
            let answer = await post("S", path: path)
            #expect(answer.status == 400, "\(path)")
            #expect(answer.body.contains(words), "\(path): \(answer.body)")
        }
        let blank = await post("S", path: " ")
        #expect(blank.status == 400, "no folder at all")
        let nobody = await post("nobody", path: new)
        #expect(nobody.status == 404)
        expectUnmoved(record, agentsBefore: before)
    }

    @Test func itMovesItsConversationKeepsItsRecordAndResumesThere() async throws {
        let record = try session()
        let first = try #require(agents.made.last)
        let answer = await post("S", path: new)
        #expect(answer.status == 200, "\(answer.body)")
        #expect(Envelope.decode(answer.body)?.sessions?.first?.cwd == new, "answered with the session there: \(answer.body)")
        #expect(first.agent.ended, "its agent ended first")
        // Its record: the folder and the resume command.
        #expect(record.info.cwd == new)
        #expect(record.info.resumeCommand == "cd \(new) && claude --resume conv-1")
        // Its conversation, in the new folder's project.
        #expect(exists(project(new) + "conv-1.jsonl"))
        #expect(!exists(project(old) + "conv-1.jsonl"))
        // Its agent made again there, on the same conversation, and started.
        let resumed = try #require(agents.made.last)
        #expect(resumed.cwd == new && resumed.resume == "conv-1", "\(agents.made.map { ($0.cwd, $0.resume) })")
        #expect(record.process === resumed.agent)
        #expect(resumed.agent.started)
        #expect(record.info.agentState == .running)
        #expect(!record.held, "what is said goes to it again")
        // Kept: sessions.json says the new folder.
        let stored = try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: VisorServer.storeURL))
        #expect(stored.first { $0.info.id == "S" }?.info.cwd == new)
    }

    @Test func aMoveThatFailsResumesItWhereItWas() async throws {
        let record = try session()
        // The new project has a conversation of the same id already: the
        // move stops before anything is moved.
        try write("{\"type\":\"user\",\"other\":true}\n", project(new) + "conv-1.jsonl")
        let said = await server.moveFolder(record, to: new)
        #expect(said?.hasPrefix("Its folder wasn't changed:") == true, "\(said ?? "moved")")
        #expect(said?.contains("is there already") == true, "\(said ?? "moved")")
        #expect(record.info.cwd == old)
        #expect(record.info.resumeCommand == "cd \(old) && claude --resume conv-1")
        #expect(exists(project(old) + "conv-1.jsonl"), "nothing deleted")
        let resumed = try #require(agents.made.last)
        #expect(resumed.cwd == old && resumed.resume == "conv-1", "resumed where it was: \(agents.made.map { ($0.cwd, $0.resume) })")
        #expect(record.process === resumed.agent)
        #expect(resumed.agent.started)
        #expect(record.info.agentState == .running)
        #expect(!record.held)
    }

    @Test func aStoppedAgentStaysStoppedInItsNewFolder() async throws {
        let record = try session()
        server.stopAgent(record)
        for _ in 0..<200 where record.info.agentState != .stopped || record.held {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let said = await server.moveFolder(record, to: new)
        #expect(said == nil, "\(said ?? "")")
        #expect(record.info.cwd == new)
        let made = try #require(agents.made.last)
        #expect(made.cwd == new && !made.agent.started, "made there, not started")
        #expect(record.info.agentState == .stopped)
    }
}
}
