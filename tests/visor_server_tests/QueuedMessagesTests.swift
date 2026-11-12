// What the user said while the agent worked goes over a message at a
// time, never run together: a slash command (`/goal clear`) stays a
// command. Between messages the turn is stopped, since the agent has the
// message and answers the last one; after the last it is not. Clearing the
// goal while the agent works toward it stops the turn and goes first.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that writes down what it is sent and when it is stopped.
@MainActor
private final class ScriptedAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    /// What it was sent, with "stop" where a turn was interrupted.
    var said: [String] = []
    /// Words it takes as a command of its own, with no turn (Codex's /goal).
    var commands: Set<String> = []

    init() { (events, emit) = AsyncStream.makeStream() }

    func send(_ text: String) throws { said.append(text) }
    func start() throws {}
    func startsTurn(_ text: String) -> Bool { !commands.contains(text) }
    func interrupt() { said.append("stop") }
    func stop() {}
    func end(within deadline: Duration) async {}
}

extension ServerTests {
@Suite @MainActor final class QueuedMessagesTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-queue-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7983)
    }

    isolated deinit {
        server.stop()
    }

    private func working(_ agent: ScriptedAgent) -> SessionRecord {
        let record = SessionRecord(info: SessionInfo(id: "q", agent: .claude, cwd: "/tmp", title: "q", created: 0), process: agent)
        server.sessions = [record]
        server.handle(.busy(true), from: record)
        return record
    }

    @Test func testQueuedMessagesGoOverOneAtATimeWithAStopBetween() {
        let agent = ScriptedAgent()
        let record = working(agent)
        for text in ["Check the logs", "/compact", "Then summarize"] { server.deliver(text, to: record) }
        #expect(record.info.queued == ["Check the logs", "/compact", "Then summarize"], "held while it works")
        #expect(agent.said.isEmpty)

        // The turn ends (or Send Now stops it): the first goes, and its turn
        // is stopped since more wait.
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["Check the logs", "stop"])
        #expect(record.info.queued == ["/compact", "Then summarize"])

        // The stopped turn ends: the command goes on its own, stopped too.
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["Check the logs", "stop", "/compact", "stop"])

        // The last goes, and is answered: no stop after it.
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["Check the logs", "stop", "/compact", "stop", "Then summarize"])
        #expect(record.info.queued.isEmpty)
        #expect(record.info.busy, "the last message's turn runs")
        server.handle(.busy(false), from: record)
        #expect(agent.said.last == "Then summarize", "nothing more")
    }

    @Test func testClearingTheGoalStopsTheTurnAndGoesFirst() {
        let agent = ScriptedAgent()
        let record = working(agent)
        server.deliver("Also update the docs", to: record)
        #expect(agent.said.isEmpty, "a message waits; typing never interrupts")
        server.deliver("/goal clear", to: record)
        #expect(record.info.queued == ["/goal clear", "Also update the docs"], "ahead of what waits")
        #expect(agent.said == ["stop"], "the goal's turn is stopped now")
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["stop", "/goal clear", "stop"])
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["stop", "/goal clear", "stop", "Also update the docs"])
        #expect(SessionRecord.clearsGoal(" /goal clear\n"))
        #expect(!SessionRecord.clearsGoal("/goal clearly better"))
    }

    /// A session held while the agent before it goes keeps its queue, and
    /// nothing goes round: after a restart this was a loop that put each
    /// message back and saved the sessions file without end.
    @Test func testAHeldSessionKeepsItsQueueUntilReleased() {
        let agent = ScriptedAgent()
        let record = working(agent)
        for text in ["One", "Two"] { server.deliver(text, to: record) }
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["One", "stop"])
        record.held = true
        server.handle(.busy(false), from: record)
        server.deliverQueued(record)
        server.resumePending()
        #expect(agent.said == ["One", "stop"], "nothing goes while held")
        #expect(record.info.queued == ["Two"], "and nothing is lost or repeated")
        server.release(record)
        #expect(agent.said == ["One", "stop", "Two"])
        #expect(record.info.queued.isEmpty)
    }

    @Test func testOneQueuedMessageIsSimplySent() {
        let agent = ScriptedAgent()
        let record = working(agent)
        server.deliver("/compact", to: record)
        server.handle(.busy(false), from: record)
        #expect(agent.said == ["/compact"])
    }

    @Test func testACommandThatStartsNoTurnIsFollowedAtOnce() {
        let agent = ScriptedAgent()
        agent.commands = ["/goal Ship it"]
        let record = working(agent)
        for text in ["/goal Ship it", "What's left?"] { server.deliver(text, to: record) }
        server.handle(.busy(false), from: record)
        // No turn to stop after the command: the next goes straight after it.
        #expect(agent.said == ["/goal Ship it", "What's left?"])
        #expect(record.info.queued.isEmpty)
    }
}
}
