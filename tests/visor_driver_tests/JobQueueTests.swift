// Visor's dispatcher (VisorDriver's JobQueue): a job queued is claimed by a
// runner that runs its harness; a runner waiting is woken by a job; a
// claim renewed holds; a job released, or whose claim lapses, goes back;
// one completed or failed is done. And the native runner's wrapper is
// given the job as a runner gives it.

import AgentProtocol
@testable import VisorDriver
@testable import VisorNativeRunner
import VisorProtocol
import VisorServer
import Foundation
import Testing

@Suite @MainActor final class JobQueueTests {
    private func claim(_ capabilities: [String] = ["native", "harness:claude"]) -> AgentProtocol_V1_ClaimRequest {
        .with { $0.runner = "Mac"; $0.capabilities = capabilities }
    }

    private func start(_ title: String) -> Envelope {
        var e = Envelope(type: "job")
        e.agent = .claude
        e.title = title
        e.text = "Begin"
        e.cwd = "/tmp/work"
        return e
    }

    private func queue(harness: String = "claude") -> JobQueue {
        JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", harness: harness, log: { _ in })
    }

    @Test func testAQueuedJobIsClaimedOnceKeptWhileRenewedAndDoneWhenCompleted() async throws {
        let jobs = queue()
        let agent = try jobs.queueStart(start("A task")).get()
        let claimed = await jobs.claim(claim(), wait: .zero)
        let job = try #require(claimed)
        #expect(job.agent.uuid == agent)
        #expect(job.agent.dispatcherURL == "http://127.0.0.1:7434")
        #expect(job.driverURL == "http://127.0.0.1:7434")
        #expect(job.title == "A task")
        #expect(job.prompt == "Begin")
        #expect(job.workingDirectory == "/tmp/work")
        #expect(job.hasClaimExpires)
        let again = await jobs.claim(claim(), wait: .zero)
        #expect(again == nil, "claimed once")
        #expect(jobs.renew(job.agent) != nil)
        jobs.report(.with { $0.agent = job.agent; $0.completed = .with { $0.summary = "Done" } })
        #expect(jobs.renew(job.agent) == nil, "completed is done")
    }

    @Test func testAReleasedJobGoesBackToTheFront() async throws {
        let jobs = queue()
        _ = jobs.queueStart(start("First"))
        let first = await jobs.claim(claim(), wait: .zero)
        _ = jobs.queueStart(start("Second"))
        jobs.report(.with { $0.agent = first!.agent; $0.released = .with { $0.reason = "it ended badly" } })
        let next = await jobs.claim(claim(), wait: .zero)
        #expect((next?.title) == "First")
    }

    @Test func testARunnerWaitingIsWokenByAJob() async throws {
        let jobs = queue()
        let waiting = Task { await jobs.claim(claim(), wait: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        _ = jobs.queueStart(start("Later"))
        let job = await waiting.value
        #expect((job?.title) == "Later")
    }

    @Test func testARunnerTakesOnlyTheHarnessesItRuns() async {
        let jobs = queue(harness: "echo")
        _ = jobs.queueStart(start("Echoed"))
        let claudeOnly = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        #expect(claudeOnly == nil)
        let echoing = await jobs.claim(claim(["native", "harness:echo"]), wait: .zero)
        #expect((echoing?.harness) == "echo")
        var codex = Envelope(type: "job")
        codex.agent = .codex
        #expect(jobs.queueStart(codex) == (.failure(AgentJobRefusal("Runners run Claude Code agents for now."))))
    }

    @Test func testAJobThatAsksForAKindOfRunnerGoesOnlyToOne() async {
        let jobs = queue()
        var contained = start("Contained")
        contained.runsOn = "container"
        _ = jobs.queueStart(contained)
        _ = jobs.queueStart(start("Anywhere"))
        let native = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        #expect((native?.title) == "Anywhere")
        let container = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        #expect((container?.title) == "Contained")
        #expect((container?.labels) == ["runs-on:container"])
    }

    @Test func testAnIdSpelledInUpperCaseIsTheSameAgent() async throws {
        let jobs = queue()
        _ = jobs.queueStart(start("Shouted"))
        let claimed = await jobs.claim(claim(), wait: .zero)
        let job = try #require(claimed)
        var upper = job.agent
        upper.uuid = upper.uuid.uppercased()
        #expect(jobs.renew(upper) != nil)
        jobs.report(.with { $0.agent = upper; $0.completed = .init() })
        #expect(jobs.renew(job.agent) == nil, "Completed in upper case let the claim go")
    }

    @Test func testAContainerRunnerIsGivenTheAddressContainersReach() async throws {
        let jobs = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434",
                            containerURL: "http://visor.multipass.internal:7434", log: { _ in })
        _ = jobs.queueStart(start("Native"))
        _ = jobs.queueStart(start("Contained"))
        let nativeClaim = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        let native = try #require(nativeClaim)
        #expect(native.agent.dispatcherURL == "http://127.0.0.1:7434")
        #expect(native.driverURL == "http://127.0.0.1:7434")
        let containedClaim = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let contained = try #require(containedClaim)
        #expect(contained.agent.dispatcherURL == "http://visor.multipass.internal:7434")
        #expect(contained.driverURL == "http://visor.multipass.internal:7434")
        #expect((jobs.claimed[contained.agent.uuid]?.job.driverURL) == "http://127.0.0.1:7434", "the job kept keeps its own")
    }

    @Test func testAMovedSessionsResumeJobCarriesItsConversationAndRepositories() async throws {
        let jobs = queue()
        let move = AgentJobMove(session: "s7abc", title: "Moved", resume: "c-123", cwd: "/Users/logan/Developer",
                                sources: [AgentJobSource(repository: "https://github.com/AttilaTheFun/visor.git", ref: "main", name: "visor")],
                                runsOn: "container")
        #expect(jobs.queueResume(move) == .success("s7abc"))
        #expect(jobs.queueResume(move) == (.failure(AgentJobRefusal("The session is moving to a runner already."))))
        let nativeClaim = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        #expect(nativeClaim == nil, "only a container runner takes it")
        let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let job = try #require(claimed)
        // The job's agent is a UUID, as runners hold an agent's id to be; it
        // is the session's.
        #expect(UUID(uuidString: job.agent.uuid) != nil, Comment(rawValue: job.agent.uuid))
        #expect(job.agent.uuid == job.agent.uuid.lowercased())
        #expect(jobs.session(of: job.agent.uuid) == "s7abc")
        #expect(jobs.session(of: job.agent.uuid.uppercased()) == "s7abc")
        #expect(jobs.session(of: "a1b2") == "a1b2", "an agent that isn't a move's is its own session")
        #expect(job.resumeSessionID == "c-123")
        #expect(job.sources.map(\.name) == ["visor"])
        #expect((job.sources.first?.ref) == "main")
        let known = jobs.move(of: job.agent)
        #expect((known?.resume) == "c-123")
        #expect((known?.cwd) == "/Users/logan/Developer")
        #expect((jobs.queueResume(AgentJobMove(session: "s8", title: "None", resume: "", cwd: "/", runsOn: "container"))) == (.failure(AgentJobRefusal("The session has no conversation to carry on."))))
        let json = NativeRunner.json(job)
        #expect(json.contains("\"resumeSessionID\":\"c-123\""), Comment(rawValue: json))
        #expect(json.contains("\"sources\":[{"), Comment(rawValue: json))
    }

    /// A job whose agent ends at once every time it is given out is given
    /// up after `JobQueue.attempts`, not handed round and round (12 Nov: a
    /// wrapper that couldn't reach the driver came back every second).
    @Test func aJobThatKeepsComingBackUnexplainedIsGivenUp() async throws {
        let jobs = queue()
        let move = AgentJobMove(session: "s9", title: "Moved", resume: "c-9", cwd: "/tmp", runsOn: "container")
        #expect(jobs.queueResume(move) == .success("s9"))
        for attempt in 1...JobQueue.attempts {
            let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
            let job = try #require(claimed, "given out, attempt \(attempt)")
            jobs.report(.with { $0.agent = job.agent; $0.released = .with { $0.reason = "its agent ended (status 1)" } })
        }
        let again = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        #expect(again == nil, "given up")
        #expect(jobs.movedSessions.isEmpty)
    }

    /// An agent that started, and comes back each time its runner restarts,
    /// is never given up: a start clears the count.
    @Test func aJobThatStartedIsNotGivenUpForItsRunnersRestarts() async throws {
        let jobs = queue()
        let move = AgentJobMove(session: "s12", title: "Moved", resume: "c-12", cwd: "/tmp", runsOn: "container")
        #expect(jobs.queueResume(move) == .success("s12"))
        for restart in 1...(JobQueue.attempts + 2) {
            let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
            let job = try #require(claimed, "given out again, restart \(restart)")
            jobs.report(.with { $0.agent = job.agent; $0.started = .with { $0.runner = "primary@mini"; $0.sessionID = "c-12" } })
            jobs.report(.with { $0.agent = job.agent; $0.released = .with { $0.reason = "its runner restarted" } })
        }
        #expect(jobs.movedSessions.values.contains("s12"), "still the session's")
    }

    /// A session ended takes its job with it, waiting or claimed: its
    /// runner's next renewal is refused.
    @Test func anEndedSessionsJobGoes() async throws {
        let jobs = queue()
        #expect(jobs.queueResume(AgentJobMove(session: "s10", title: "A", resume: "c-10", cwd: "/tmp", runsOn: "container")) == .success("s10"))
        #expect(jobs.queueResume(AgentJobMove(session: "s11", title: "B", resume: "c-11", cwd: "/tmp", runsOn: "container")) == .success("s11"))
        let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let first = try #require(claimed)
        #expect(jobs.session(of: first.agent.uuid) == "s10")
        jobs.forget(session: "s10")
        jobs.forget(session: "s11")
        #expect(jobs.renew(first.agent) == nil, "its claim is refused")
        let next = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        #expect(next == nil, "the waiting one went too")
    }

    /// A move whose job fails, or is given up, tells the server to bring
    /// its session back, with its conversation and folder (13 Nov: a
    /// clone that failed left the session waiting, its agent here ended).
    @Test func aFailedMoveBringsItsSessionBack() async throws {
        let jobs = queue()
        var back: [String] = []
        jobs.moveFailed = { session, resume, cwd, why in back.append("\(session) \(resume) \(cwd): \(why)") }
        #expect(jobs.queueResume(AgentJobMove(session: "s12", title: "A", resume: "c-12", cwd: "/Users/a", runsOn: "container")) == .success("s12"))
        let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let job = try #require(claimed)
        jobs.report(.with { $0.agent = job.agent; $0.failed = .with { $0.reason = "git clone ended with 128" } })
        #expect(back == ["s12 c-12 /Users/a: git clone ended with 128"])
        #expect(jobs.movedSessions.isEmpty)

        #expect(jobs.queueResume(AgentJobMove(session: "s13", title: "B", resume: "c-13", cwd: "/Users/b", runsOn: "container")) == .success("s13"))
        for _ in 1...JobQueue.attempts {
            let next = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
            let again = try #require(next)
            jobs.report(.with { $0.agent = again.agent; $0.released = .with { $0.reason = "status 1" } })
        }
        #expect(back.count == 2)
        #expect(back.last?.hasPrefix("s13 c-13 /Users/b: ") == true, Comment(rawValue: back.last ?? ""))
    }

    @Test func testTheNativeRunnerGivesItsWrapperTheJob() async throws {
        let runner = try #require(NativeRunner(dispatcher: "http://127.0.0.1:7434", wrapper: "/bin/true", name: "Mac", log: { _ in }))
        var job = AgentProtocol_V1_Job()
        job.agent = .with { $0.uuid = "u1"; $0.dispatcherURL = "http://127.0.0.1:7434" }
        job.title = "T"
        job.prompt = "P"
        job.harness = "echo"
        job.workingDirectory = "/w"
        job.driverURL = "http://127.0.0.1:7434"
        let environment = await runner.environment(for: job)
        #expect((environment["AGENT_ID"]) == "u1@http://127.0.0.1:7434")
        #expect((environment["AGENT_DISPATCHER_URL"]) == "http://127.0.0.1:7434")
        #expect((environment["AGENT_DRIVER_URL"]) == "http://127.0.0.1:7434")
        #expect((environment["AGENT_RUNNER"]) == "Mac")
        let agentJob = try #require(environment["AGENT_JOB"])
        let given = try #require(JSONSerialization.jsonObject(with: Data(agentJob.utf8)) as? [String: Any])
        #expect((given["agent"] as? String) == "u1")
        #expect((given["harness"] as? String) == "echo")
        #expect((given["workingDirectory"] as? String) == "/w")
        #expect((given["prompt"] as? String) == "P")
        #expect((given["model"]) == nil, "nothing for what the job doesn't say")
    }
}
