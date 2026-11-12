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
        let given = try #require(JSONSerialization.jsonObject(with: Data(try #require(environment["AGENT_JOB"]).utf8)) as? [String: Any])
        #expect((given["agent"] as? String) == "u1")
        #expect((given["harness"] as? String) == "echo")
        #expect((given["workingDirectory"] as? String) == "/w")
        #expect((given["prompt"] as? String) == "P")
        #expect((given["model"]) == nil, "nothing for what the job doesn't say")
    }
}
