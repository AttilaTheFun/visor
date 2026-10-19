// A session's agent, stopped, started and restarted as the user asks:
// stopping until the old agent has gone, then stopped, with what is said
// meanwhile kept in the queue; started (its process up at once), and what
// waited goes over; restarted through stopping and starting. A stopped
// agent stays stopped through a launch of the server.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

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

@MainActor
final class AgentStateTests: ServerTestCase {
    private var server: VisorServer!
    private let agents = Agents()

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-state-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7988)
        server.harnesses = AgentHarnesses([LoggedHarness(agents)])
    }

    override func tearDown() async throws {
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
        XCTAssertEqual(record.info.agentState, state)
    }

    func testANewSessionsAgentRuns() {
        XCTAssertEqual(session().info.agentState, .running)
    }

    func testStoppedTheMessageWaitsAndStartingSendsIt() async throws {
        let record = session()
        let first = try XCTUnwrap(agents.made.last)
        act("stopAgent", on: record)
        XCTAssertEqual(record.info.agentState, .stopping)
        try await settle(record, at: .stopped)
        XCTAssertTrue(first.ended)

        server.deliver("Carry on", to: record)
        XCTAssertEqual(record.info.queued, ["Carry on"], "kept while the agent is stopped")
        let stopped = try XCTUnwrap(agents.made.last)
        XCTAssertFalse(stopped.started)

        // Neither stopped again nor restarted while stopped (an old
        // client's Restart starts it).
        act("stopAgent", on: record)
        XCTAssertEqual(record.info.agentState, .stopped)

        act("startAgent", on: record)
        XCTAssertEqual(record.info.agentState, .running)
        XCTAssertTrue(stopped.started, "its process up at once")
        XCTAssertEqual(stopped.said, ["Carry on"])
        XCTAssertTrue(record.info.queued.isEmpty)
    }

    func testRestartEndsTheAgentAndStartsANewOne() async throws {
        let record = session()
        let first = try XCTUnwrap(agents.made.last)
        act("startAgent", on: record)
        XCTAssertEqual(agents.made.count, 1, "a running agent is not started again")

        act("restartAgent", on: record)
        XCTAssertEqual(record.info.agentState, .stopping)
        try await settle(record, at: .running)
        XCTAssertTrue(first.ended)
        let second = try XCTUnwrap(agents.made.last)
        XCTAssertFalse(second === first)
        XCTAssertTrue(second.started, "started at once, not by the next message")
    }

    func testAStoppedAgentStaysStoppedThroughALaunch() async throws {
        let record = session()
        act("stopAgent", on: record)
        try await settle(record, at: .stopped)
        server.saveArchive()

        let again = VisorServer(port: 7989)
        again.harnesses = AgentHarnesses([LoggedHarness(agents)])
        again.loadSessions()
        XCTAssertEqual(again.session("S")?.info.agentState, .stopped)
        again.stop()
    }

    func testArchivingStopsAndUnarchivingRuns() {
        let record = session()
        server.archive(record)
        XCTAssertEqual(record.info.agentState, .stopped)
        XCTAssertEqual(SessionInfo(json: record.info.json)?.agentState, .stopped, "told over the wire")
        server.unarchive(record)
        XCTAssertEqual(record.info.agentState, .running)
    }
}
