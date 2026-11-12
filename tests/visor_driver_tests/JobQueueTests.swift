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
import XCTest

@MainActor
final class JobQueueTests: XCTestCase {
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

    func testAQueuedJobIsClaimedOnceKeptWhileRenewedAndDoneWhenCompleted() async throws {
        let jobs = queue()
        let agent = try jobs.queueStart(start("A task")).get()
        let claimed = await jobs.claim(claim(), wait: .zero)
        let job = try XCTUnwrap(claimed)
        XCTAssertEqual(job.agent.uuid, agent)
        XCTAssertEqual(job.agent.dispatcherURL, "http://127.0.0.1:7434")
        XCTAssertEqual(job.driverURL, "http://127.0.0.1:7434")
        XCTAssertEqual(job.title, "A task")
        XCTAssertEqual(job.prompt, "Begin")
        XCTAssertEqual(job.workingDirectory, "/tmp/work")
        XCTAssertTrue(job.hasClaimExpires)
        let again = await jobs.claim(claim(), wait: .zero)
        XCTAssertNil(again, "claimed once")
        XCTAssertNotNil(jobs.renew(job.agent))
        jobs.report(.with { $0.agent = job.agent; $0.completed = .with { $0.summary = "Done" } })
        XCTAssertNil(jobs.renew(job.agent), "completed is done")
    }

    func testAReleasedJobGoesBackToTheFront() async throws {
        let jobs = queue()
        _ = jobs.queueStart(start("First"))
        let first = await jobs.claim(claim(), wait: .zero)
        _ = jobs.queueStart(start("Second"))
        jobs.report(.with { $0.agent = first!.agent; $0.released = .with { $0.reason = "it ended badly" } })
        let next = await jobs.claim(claim(), wait: .zero)
        XCTAssertEqual(next?.title, "First")
    }

    func testARunnerWaitingIsWokenByAJob() async throws {
        let jobs = queue()
        let waiting = Task { await jobs.claim(claim(), wait: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        _ = jobs.queueStart(start("Later"))
        let job = await waiting.value
        XCTAssertEqual(job?.title, "Later")
    }

    func testARunnerTakesOnlyTheHarnessesItRuns() async {
        let jobs = queue(harness: "echo")
        _ = jobs.queueStart(start("Echoed"))
        let claudeOnly = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        XCTAssertNil(claudeOnly)
        let echoing = await jobs.claim(claim(["native", "harness:echo"]), wait: .zero)
        XCTAssertEqual(echoing?.harness, "echo")
        var codex = Envelope(type: "job")
        codex.agent = .codex
        XCTAssertEqual(jobs.queueStart(codex), .failure(AgentJobRefusal("Runners run Claude Code agents for now.")))
    }

    func testAJobThatAsksForAKindOfRunnerGoesOnlyToOne() async {
        let jobs = queue()
        var contained = start("Contained")
        contained.runsOn = "container"
        _ = jobs.queueStart(contained)
        _ = jobs.queueStart(start("Anywhere"))
        let native = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        XCTAssertEqual(native?.title, "Anywhere")
        let container = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        XCTAssertEqual(container?.title, "Contained")
        XCTAssertEqual(container?.labels, ["runs-on:container"])
    }

    func testAnIdSpelledInUpperCaseIsTheSameAgent() async throws {
        let jobs = queue()
        _ = jobs.queueStart(start("Shouted"))
        let claimed = await jobs.claim(claim(), wait: .zero)
        let job = try XCTUnwrap(claimed)
        var upper = job.agent
        upper.uuid = upper.uuid.uppercased()
        XCTAssertNotNil(jobs.renew(upper))
        jobs.report(.with { $0.agent = upper; $0.completed = .init() })
        XCTAssertNil(jobs.renew(job.agent), "Completed in upper case let the claim go")
    }

    func testAContainerRunnerIsGivenTheAddressContainersReach() async throws {
        let jobs = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434",
                            containerURL: "http://visor.multipass.internal:7434", log: { _ in })
        _ = jobs.queueStart(start("Native"))
        _ = jobs.queueStart(start("Contained"))
        let nativeClaim = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        let native = try XCTUnwrap(nativeClaim)
        XCTAssertEqual(native.agent.dispatcherURL, "http://127.0.0.1:7434")
        XCTAssertEqual(native.driverURL, "http://127.0.0.1:7434")
        let containedClaim = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let contained = try XCTUnwrap(containedClaim)
        XCTAssertEqual(contained.agent.dispatcherURL, "http://visor.multipass.internal:7434")
        XCTAssertEqual(contained.driverURL, "http://visor.multipass.internal:7434")
        XCTAssertEqual(jobs.claimed[contained.agent.uuid]?.job.driverURL, "http://127.0.0.1:7434", "the job kept keeps its own")
    }

    func testAMovedSessionsResumeJobCarriesItsConversationAndRepositories() async throws {
        let jobs = queue()
        let move = AgentJobMove(session: "s7abc", title: "Moved", resume: "c-123", cwd: "/Users/logan/Developer",
                                sources: [AgentJobSource(repository: "https://github.com/AttilaTheFun/visor.git", ref: "main", name: "visor")],
                                runsOn: "container")
        XCTAssertEqual(jobs.queueResume(move), .success("s7abc"))
        XCTAssertEqual(jobs.queueResume(move), .failure(AgentJobRefusal("The session is moving to a runner already.")))
        let nativeClaim = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        XCTAssertNil(nativeClaim, "only a container runner takes it")
        let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let job = try XCTUnwrap(claimed)
        XCTAssertEqual(job.agent.uuid, "s7abc")
        XCTAssertEqual(job.resumeSessionID, "c-123")
        XCTAssertEqual(job.sources.map(\.name), ["visor"])
        XCTAssertEqual(job.sources.first?.ref, "main")
        let known = jobs.move(of: job.agent)
        XCTAssertEqual(known?.resume, "c-123")
        XCTAssertEqual(known?.cwd, "/Users/logan/Developer")
        XCTAssertEqual(jobs.queueResume(AgentJobMove(session: "s8", title: "None", resume: "", cwd: "/", runsOn: "container")),
                       .failure(AgentJobRefusal("The session has no conversation to carry on.")))
        let json = NativeRunner.json(job)
        XCTAssertTrue(json.contains("\"resumeSessionID\":\"c-123\""), json)
        XCTAssertTrue(json.contains("\"sources\":[{"), json)
    }

    func testTheNativeRunnerGivesItsWrapperTheJob() async throws {
        let runner = try XCTUnwrap(NativeRunner(dispatcher: "http://127.0.0.1:7434", wrapper: "/bin/true", name: "Mac", log: { _ in }))
        var job = AgentProtocol_V1_Job()
        job.agent = .with { $0.uuid = "u1"; $0.dispatcherURL = "http://127.0.0.1:7434" }
        job.title = "T"
        job.prompt = "P"
        job.harness = "echo"
        job.workingDirectory = "/w"
        job.driverURL = "http://127.0.0.1:7434"
        let environment = await runner.environment(for: job)
        XCTAssertEqual(environment["AGENT_ID"], "u1@http://127.0.0.1:7434")
        XCTAssertEqual(environment["AGENT_DISPATCHER_URL"], "http://127.0.0.1:7434")
        XCTAssertEqual(environment["AGENT_DRIVER_URL"], "http://127.0.0.1:7434")
        XCTAssertEqual(environment["AGENT_RUNNER"], "Mac")
        let given = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(environment["AGENT_JOB"]).utf8)) as? [String: Any])
        XCTAssertEqual(given["agent"] as? String, "u1")
        XCTAssertEqual(given["harness"] as? String, "echo")
        XCTAssertEqual(given["workingDirectory"] as? String, "/w")
        XCTAssertEqual(given["prompt"] as? String, "P")
        XCTAssertNil(given["model"], "nothing for what the job doesn't say")
    }
}
