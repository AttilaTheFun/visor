// A session's agent, stopped, started and restarted as the user asks:
// stopping until the old agent has gone, then stopped, with what is said
// meanwhile kept in the queue; started (its process up at once), and what
// waited goes over; restarted through stopping and starting. A stopped
// agent stays stopped through a launch of the server.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// The agents a harness made, each writing down what it was asked.
@MainActor
private final class Agents {
    var made: [LoggedAgent] = []
}

@MainActor
private final class LoggedAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { "resume-id" }
    var resumeCommand: String? { nil }
    var processID: Int32? { started ? 4242 : nil }
    var started = false
    var ended = false
    var said: [String] = []

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {
        started = true
        said.append(text)
    }

    func start() throws { started = true }
    func interrupt() {}
    func stop() { ended = true }
    func end(within deadline: Duration) async { ended = true }
}

private final class LoggedHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"
    let agents: Agents

    init(_ agents: Agents) { self.agents = agents }

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: []) }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess {
        let agent = LoggedAgent()
        agents.made.append(agent)
        return agent
    }
}

extension ServerTests {
@Suite @MainActor final class AgentStateTests {
    private var server: VisorServer!
    private let agents = Agents()

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-state-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7988)
        server.harnesses = AgentHarnesses([LoggedHarness(agents)])
    }

    isolated deinit {
        server.stop()
    }

    private func session() -> SessionRecord {
        let info = SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "S", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil))
        server.sessions = [record]
        return record
    }

    private func act(_ type: String, on record: SessionRecord) {
        var envelope = Envelope(type: type)
        envelope.session = record.info.id
        server.perform(envelope, from: nil)
    }

    /// Until the server has done with the agent before (its end is awaited
    /// in a task of its own).
    private func settle(_ record: SessionRecord, at state: AgentState) async throws {
        for _ in 0..<200 where record.info.agentState != state || record.held {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(record.info.agentState == state)
    }

    @Test func testANewSessionsAgentRuns() {
        #expect(session().info.agentState == .running)
    }

    @Test func testStoppedTheMessageWaitsAndStartingSendsIt() async throws {
        let record = session()
        let first = try #require(agents.made.last)
        act("stopAgent", on: record)
        #expect(record.info.agentState == .stopping)
        try await settle(record, at: .stopped)
        #expect(first.ended)

        server.deliver("Carry on", to: record)
        #expect(record.info.queued == ["Carry on"], "kept while the agent is stopped")
        let stopped = try #require(agents.made.last)
        #expect(!stopped.started)

        // Neither stopped again nor restarted while stopped (an old
        // client's Restart starts it).
        act("stopAgent", on: record)
        #expect(record.info.agentState == .stopped)

        act("startAgent", on: record)
        #expect(record.info.agentState == .running)
        #expect(stopped.started, "its process up at once")
        #expect(stopped.said == ["Carry on"])
        #expect(record.info.queued.isEmpty)
    }

    @Test func testRestartEndsTheAgentAndStartsANewOne() async throws {
        let record = session()
        let first = try #require(agents.made.last)
        act("startAgent", on: record)
        #expect(agents.made.count == 1, "a running agent is not started again")

        act("restartAgent", on: record)
        #expect(record.info.agentState == .stopping)
        try await settle(record, at: .running)
        #expect(first.ended)
        let second = try #require(agents.made.last)
        #expect(!(second === first))
        #expect(second.started, "started at once, not by the next message")
    }

    @Test func testAStoppedAgentStaysStoppedThroughALaunch() async throws {
        let record = session()
        act("stopAgent", on: record)
        try await settle(record, at: .stopped)
        server.saveArchiveNow()

        let again = VisorServer(port: 7989)
        again.harnesses = AgentHarnesses([LoggedHarness(agents)])
        again.loadSessions()
        #expect((again.session("S")?.info.agentState) == .stopped)
        again.stop()
    }

    @Test func testArchivingStopsAndUnarchivingRuns() {
        let record = session()
        server.archive(record)
        #expect(record.info.agentState == .stopped)
        #expect((SessionInfo(json: record.info.json)?.agentState) == .stopped, "told over the wire")
        server.unarchive(record)
        #expect(record.info.agentState == .running)
    }
}
}
