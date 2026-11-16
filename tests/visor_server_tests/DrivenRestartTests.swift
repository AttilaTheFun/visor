// Sessions moved to runners (driven) stay where they run (visor#424): a
// relaunch or a quit leaves their runners' agents working; a restart reads
// them back as driven, with their moves, and hands those to the dispatcher;
// Start, Stop and Restart Agent act on the runner, never starting an agent
// here; and a move clears the notice an earlier one left.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// A runner's agent as the server holds it (VisorDriver's DrivenProcess in
/// the app): told to stop or end, and nothing else.
@MainActor
private final class RunnerAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    private(set) var stopped = false
    private(set) var ended = false
    private(set) var started = false

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws { started = true }
    func interrupt() {}
    func stop() { stopped = true }
    func end(within deadline: Duration) async { ended = true }
}

/// An agent of this computer's with a conversation, for a session about to
/// move.
@MainActor
private final class NativeAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = false
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { "c-native" }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

/// The dispatcher as the server sees it: what it was asked.
@MainActor
private final class Jobs: AgentJobQueue {
    var queued: [AgentJobMove] = []
    var stopped: [String] = []
    var forgotten: [String] = []
    var adopted: [AgentJobMove] = []
    var expected: Set<String> = []
    var keptMoves: [String: AgentJobMove] = [:]

    func queueStart(_ request: Envelope) -> Result<String, AgentJobRefusal> { .failure(AgentJobRefusal("not here")) }

    func queueResume(_ move: AgentJobMove) -> Result<String, AgentJobRefusal> {
        queued.append(move)
        return .success(move.session)
    }

    func forget(session: String) { forgotten.append(session) }
    func stopJobs(of session: String) { stopped.append(session) }

    func adopt(_ moves: [AgentJobMove], expected: Set<String>) {
        adopted += moves
        self.expected.formUnion(expected)
    }

    func kept(session: String) -> AgentJobMove? { keptMoves[session] }
}

extension ServerTests {
@Suite @MainActor final class DrivenRestartTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-driven-restart-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7993)
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func move(_ session: String, agent: String = "a-1") -> AgentJobMove {
        AgentJobMove(agent: agent, session: session, title: "Moved", resume: "c-1", cwd: "/Users/a/Developer",
                     sources: [AgentJobSource(repository: "https://github.com/o/r.git", ref: "main", name: "r")],
                     runsOn: "container", workingDirectory: "/Volumes/Sessions/claude/\(agent)", conversation: "c-2")
    }

    /// A driven session, its runner's agent `runner`, its move `move`.
    @discardableResult
    private func driven(_ id: String, runner: RunnerAgent, move: AgentJobMove? = nil) -> SessionRecord {
        let record = server.takeDriven(SessionInfo(id: id, agent: .claude, cwd: "/Volumes/Sessions/claude/a-1", title: "Moved", created: 0),
                                       process: runner)
        record.move = move ?? self.move(id)
        return record
    }

    @Test func aRelaunchOrAQuitLeavesDrivenSessionsRunning() async {
        let runner = RunnerAgent()
        driven("d1", runner: runner)
        await server.leaveAgents()
        #expect(!runner.stopped && !runner.ended, "a relaunch leaves the runner's agent working")
        await server.endAll()
        #expect(!runner.stopped && !runner.ended, "so does a quit")
    }

    @Test func aRestartReadsDrivenSessionsBackWithTheirMovesAndStartsNothingHere() throws {
        let record = driven("d2", runner: RunnerAgent())
        record.interrupted = true
        server.saveArchiveNow()
        server.stop()

        let again = VisorServer(port: 7994)
        defer { again.stop() }
        let back = try #require(again.session("d2"))
        #expect(back.driven, "kept as driven (visor#424: it came back as this computer's)")
        #expect(back.move == move("d2"))
        #expect(back.process is AwaitingDriverProcess, "no agent of this computer's until the driver is there")
        #expect(throws: (any Error).self) { try back.process.send("hello") }
        #expect(!again.pendingResumes.contains("d2"), "its runner's agent carried on: no nudge")

        let jobs = Jobs()
        again.jobs = jobs
        again.drivenProcess = { _ in RunnerAgent() }
        again.takeUpDrivenSessions()
        #expect(back.process is RunnerAgent)
        #expect(jobs.adopted == [move("d2")], "the dispatcher is given the move, jobs.json or not")
        #expect(jobs.expected == ["a-1"], "and expects its agent back")
    }

    @Test func aDrivenSessionWithoutAMoveTakesTheDispatchersOrSaysItIsUnknown() {
        let jobs = Jobs()
        server.jobs = jobs
        server.drivenProcess = { _ in RunnerAgent() }
        let known = server.takeDriven(SessionInfo(id: "d3", agent: .claude, cwd: "/tmp", title: "Known", created: 0), process: RunnerAgent())
        let unknown = server.takeDriven(SessionInfo(id: "d4", agent: .claude, cwd: "/tmp", title: "Unknown", created: 0), process: RunnerAgent())
        jobs.keptMoves["d3"] = move("d3", agent: "a-3")
        server.takeUpDrivenSessions()
        #expect(known.move == move("d3", agent: "a-3"))
        #expect(unknown.move == nil)
        #expect(unknown.notice?.hasPrefix("Visor doesn't know which runner's agent carries this session on.") == true)
        #expect(unknown.driven, "still driven: never quietly this computer's")
    }

    /// The live pilot of 16 Nov: Stop Agent, then Start Agent, on a moved
    /// session started a native claude on the Mac, on a fresh conversation.
    @Test func stopThenStartAgentOnADrivenSessionQueuesAResumeJobAndStartsNothingHere() throws {
        let jobs = Jobs()
        server.jobs = jobs
        server.drivenProcess = { _ in RunnerAgent() }
        let runner = RunnerAgent()
        let record = driven("d5", runner: runner)

        server.stopAgent(record)
        #expect(runner.stopped, "the runner's agent is told to stop")
        #expect(jobs.stopped == ["d5"], "and its job let go")
        #expect(record.info.agentState == .stopped)
        #expect(record.driven)
        #expect(record.process is RunnerAgent && record.process !== runner, "a fresh driven process: the stop isn't held for the next agent")

        server.startAgent(record)
        #expect(record.driven, "still driven")
        #expect(record.process is RunnerAgent, "no agent of this computer's")
        #expect(!(record.process as? RunnerAgent)!.started)
        let job = try #require(jobs.queued.last)
        #expect(jobs.queued.count == 1)
        #expect(job.session == "d5")
        #expect(job.resumeOnRunner == "c-2", "its runner's own conversation")
        #expect(job.workingDirectory == "/Volumes/Sessions/claude/a-1", "in the folder it worked in there")
        #expect(job.runsOn == "container")
        #expect(job.resume == "c-1" && job.cwd == "/Users/a/Developer", "its conversation and folder here kept")
        #expect(!job.agent.isEmpty && job.agent != "a-1", "a new agent: the last may still be on its way out")
        #expect(record.move == job)
        #expect(record.info.agentState == .starting)

        server.restartAgent(record)
        #expect(jobs.queued.count == 2, "Restart Agent queues a resume job too")
        #expect(record.driven)
        #expect(!server.carriesDriven("d5", agent: job.agent), "the agent before isn't the session's any more")
        #expect(server.carriesDriven("d5", agent: jobs.queued[1].agent.uppercased()))
    }

    @Test func aDrivenSessionWhoseConversationIsUnknownIsNotStartedHere() {
        server.jobs = Jobs()
        server.drivenProcess = { _ in RunnerAgent() }
        let record = server.takeDriven(SessionInfo(id: "d6", agent: .claude, cwd: "/tmp", title: "Lost", created: 0), process: RunnerAgent())
        server.startAgent(record)
        #expect(record.driven)
        #expect(record.process is RunnerAgent)
        #expect(record.notice?.contains("isn't known here") == true)
    }

    @Test func aMoveToARunnerClearsTheNoticeAndKeepsTheMoveOnTheSession() async throws {
        let jobs = Jobs()
        server.jobs = jobs
        server.drivenProcess = { _ in RunnerAgent() }
        let cwd = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let record = server.takeDriven(SessionInfo(id: "n1", agent: .claude, cwd: cwd, title: "Here", created: 0), process: NativeAgent())
        record.driven = false
        record.process = NativeAgent()
        record.notice = "Back on this computer: its runner's agent ended 3 times without starting"
        let result = await server.moveToRunner("n1", runsOn: "container")
        if case .failure(let refusal) = result { Issue.record("refused: \(refusal.reason)") }
        #expect(record.notice == nil, "a stale notice misled visor#424")
        #expect(record.driven)
        let job = try #require(jobs.queued.first)
        #expect(!job.agent.isEmpty)
        #expect(job.resume == "c-native")
        #expect(record.move == job)
    }

    @Test func aMoveBackIsDatedAndForgetsTheMove() {
        let record = driven("d7", runner: RunnerAgent())
        _ = server.moveBack("d7", resume: "c-1", cwd: "/tmp", why: "test")
        #expect(record.move == nil)
        #expect(record.notice?.hasPrefix("Back on this computer: test (") == true)
        #expect(record.notice?.hasSuffix(" UTC)") == true)
    }
}
}
