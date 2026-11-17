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
import GRPCCore
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
                            containerURL: VisorDriver.containerURL(port: 7434), log: { _ in })
        _ = jobs.queueStart(start("Native"))
        _ = jobs.queueStart(start("Contained"))
        let nativeClaim = await jobs.claim(claim(["native", "harness:claude"]), wait: .zero)
        let native = try #require(nativeClaim)
        #expect(native.agent.dispatcherURL == "http://127.0.0.1:7434")
        #expect(native.driverURL == "http://127.0.0.1:7434")
        let containedClaim = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let contained = try #require(containedClaim)
        #expect(contained.agent.dispatcherURL == "http://visor.agent.internal:7434")
        #expect(contained.driverURL == "http://visor.agent.internal:7434")
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

    /// A server that restarts keeps its queue (jobs.json): the claims its
    /// runners hold are still theirs to renew, and a moved session's agent
    /// is still its session's (14 Nov: every session in a container came
    /// back when the server restarted).
    @Test func aRestartedQueueKeepsItsClaimsAndItsMovedSessions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", file: file, log: { _ in })
        let move = AgentJobMove(session: "s7abc", title: "Moved", resume: "c-123", cwd: "/Users/a/Developer",
                                sources: [AgentJobSource(repository: "https://github.com/o/r.git", ref: "main", name: "r")],
                                runsOn: "container")
        #expect(before.queueResume(move) == .success("s7abc"))
        let claimed = await before.claim(claim(["container", "harness:claude"]), wait: .zero)
        let job = try #require(claimed)
        before.report(.with { $0.agent = job.agent; $0.started = .with { $0.runner = "primary"; $0.sessionID = "c-123" } })
        _ = try before.queueStart(start("Waiting")).get()

        let after = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", file: file, log: { _ in })
        #expect(after.renew(job.agent) != nil, "the runner's claim is still its own")
        #expect(after.session(of: job.agent.uuid) == "s7abc")
        #expect((after.move(of: job.agent)?.resume) == "c-123")
        #expect(after.waiting.map(\.title) == ["Waiting"])
        #expect((after.claimed[job.agent.uuid]?.job.sources.first?.name) == "r")
        #expect(after.queueResume(move) == .failure(AgentJobRefusal("The session is moving to a runner already.")))

        after.report(.with { $0.agent = job.agent; $0.completed = .with { $0.summary = "Done" } })
        let later = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", file: file, log: { _ in })
        #expect(later.renew(job.agent) == nil, "done stays done")
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

    /// A restart whose jobs.json lacks a moved session's agent (missing,
    /// or from a build before it): the move kept on the session is adopted,
    /// so its runner's renewal, report and redial are the session's, not
    /// dropped (visor#424).
    @Test func aMoveKeptOnTheSessionIsAdoptedWithoutJobsJson() async throws {
        let jobs = queue()
        let move = AgentJobMove(agent: "A1B2C3D4-0000-4000-8000-000000000001", session: "s20", title: "Moved", resume: "c-20",
                                cwd: "/Users/a", runsOn: "container", workingDirectory: "/Volumes/Sessions/claude/a1", conversation: "c-21")
        jobs.adopt([move], expected: [move.agent])
        let agent = AgentProtocol_V1_AgentID.with { $0.uuid = move.agent }
        #expect(jobs.session(of: move.agent) == "s20")
        #expect((jobs.move(of: agent)?.resume) == "c-20", "its conversation here, for the Conversation call")
        #expect(jobs.renew(agent) != nil, "its runner's renewal is taken")
        #expect(jobs.restored.isEmpty, "renewed: its runner is back")
        let held = try #require(jobs.claimed[Self.lower(move.agent)])
        #expect(held.job.resumeSessionID == "c-21")
        #expect(held.job.workingDirectory == "/Volumes/Sessions/claude/a1")
        #expect(held.job.labels == ["runs-on:container"])
        var started: [String] = []
        jobs.moveStarted = { session, agent, conversation in started.append("\(session) \(agent) \(conversation)") }
        jobs.report(.with { $0.agent = agent; $0.started = .with { $0.runner = "primary"; $0.sessionID = "c-22" } })
        #expect(started == ["s20 \(Self.lower(move.agent)) c-22"])
        #expect(jobs.queueResume(move) == .failure(AgentJobRefusal("The session is moving to a runner already.")))
    }

    private static func lower(_ id: String) -> String { id.lowercased() }

    /// One whose runner never comes back after the restart: given out
    /// again once its grace is over, not counted, its session told.
    @Test func anAdoptedClaimThatLapsesIsQueuedAgainUncountedAndSaysSo() async throws {
        let jobs = queue()
        var told: [String] = []
        var back: [String] = []
        jobs.moveRequeued = { session, why in told.append("\(session): \(why)") }
        jobs.moveFailed = { session, _, _, _ in back.append(session) }
        let move = AgentJobMove(agent: "b1", session: "s21", title: "Moved", resume: "c-21", cwd: "/tmp", runsOn: "container")
        jobs.adopt([move], expected: ["b1"])
        #expect(jobs.restored == ["b1"])
        for _ in 0..<(JobQueue.attempts + 1) {
            jobs.releaseLapsed(now: Date().addingTimeInterval(JobQueue.redialGrace + 1))
            if told.isEmpty { Issue.record("not told") }
            let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
            let job = try #require(claimed, "given out again")
            #expect(job.agent.uuid == "b1")
            #expect(job.resumeSessionID == "c-21")
            jobs.claimed["b1"]?.expires = Date().addingTimeInterval(-1)
            jobs.restored.insert("b1")
        }
        #expect(back.isEmpty, "never given up for a restart")
        #expect(told.first?.hasPrefix("s21: Its runner's agent didn't come back after Visor restarted") == true, Comment(rawValue: told.first ?? ""))
        #expect((jobs.returns["b1"] ?? 0) == 0)
    }

    /// A release because the dispatcher or driver was out of reach, or the
    /// host restarted, isn't a failed start; anything else still is.
    @Test func unreachableOrRestartReleasesAreNotCounted() async throws {
        let jobs = queue()
        var back: [String] = []
        jobs.moveFailed = { session, _, _, _ in back.append(session) }
        #expect(jobs.queueResume(AgentJobMove(session: "s22", title: "A", resume: "c-22", cwd: "/tmp", runsOn: "container")) == .success("s22"))
        let reasons = ["the dispatcher was unreachable", "the driver couldn't be reached: connection refused", "its host is restarting",
                       "the primary container is released: probe failed", "its claim wasn't renewed by 2026-11-16T18:00:00Z"]
        for reason in reasons + reasons {
            let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
            let job = try #require(claimed, "still given out after \(reason)")
            jobs.report(.with { $0.agent = job.agent; $0.released = .with { $0.reason = reason } })
        }
        #expect(back.isEmpty)
        #expect(jobs.returns.values.allSatisfy { $0 == 0 })
        #expect(JobQueue.mayBeStartFailure("its agent ended (status 1) without saying how it went"))
        #expect(JobQueue.mayBeStartFailure("the runner couldn't start its agent: no such file"))
        #expect(!JobQueue.mayBeStartFailure("Unreachable"))
    }

    /// Stop Agent lets the job go but keeps the session moved; the agent
    /// failing on its way out doesn't bring the session back.
    @Test func aStoppedAgentsJobGoesButItsSessionStaysMoved() async throws {
        let jobs = queue()
        var back: [String] = []
        jobs.moveFailed = { session, _, _, _ in back.append(session) }
        #expect(jobs.queueResume(AgentJobMove(agent: "c1", session: "s23", title: "A", resume: "c-23", cwd: "/tmp", runsOn: "container")) == .success("s23"))
        let claimed = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        let job = try #require(claimed)
        #expect(job.agent.uuid == "c1", "the agent the server chose")
        jobs.stopJobs(of: "s23")
        #expect(jobs.renew(job.agent) == nil, "its runner's renewal is refused")
        #expect(jobs.session(of: "c1") == "s23", "still the session's")
        jobs.report(.with { $0.agent = job.agent; $0.failed = .with { $0.reason = "terminated" } })
        #expect(back.isEmpty)
        let kept = try #require(jobs.kept(session: "s23"))
        #expect(kept.agent == "c1" && kept.resume == "c-23" && kept.runsOn == "container")
        #expect(jobs.queueResume(AgentJobMove(agent: "c2", session: "s23", title: "A", resume: "c-23", cwd: "/tmp", runsOn: "container")) == .success("s23"))
    }

    /// A job queued again while its agent was in fact alive (its runner
    /// slow to come back) is that agent's again when it renews or its
    /// wrapper dials in: never given to a second agent.
    @Test func aJobQueuedAgainIsTakenBackByItsLiveAgent() async throws {
        let jobs = queue()
        jobs.adopt([AgentJobMove(agent: "d1", session: "s24", title: "A", resume: "c-24", cwd: "/tmp", runsOn: "container")], expected: ["d1"])
        jobs.releaseLapsed(now: Date().addingTimeInterval(JobQueue.redialGrace + 1))
        #expect(jobs.waiting.map(\.agent.uuid) == ["d1"])
        jobs.heard("D1")
        #expect(jobs.waiting.isEmpty)
        #expect(jobs.claimed["d1"] != nil)
        let other = await jobs.claim(claim(["container", "harness:claude"]), wait: .zero)
        #expect(other == nil, "not given out twice")
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
        // What a runner's agent is never given from the server's own
        // environment: the admin token, Shireworks' session.
        setenv("VISOR_ADMIN_TOKEN", "admin", 1)
        setenv("SHIREWORKS_SESSION", "lease", 1)
        defer {
            unsetenv("VISOR_ADMIN_TOKEN")
            unsetenv("SHIREWORKS_SESSION")
        }
        let environment = await runner.environment(for: job)
        #expect(environment["VISOR_ADMIN_TOKEN"] == nil && environment["SHIREWORKS_SESSION"] == nil)
        #expect(!(environment["AGENT_JOB"] ?? "").contains("admin"), "nor in its job")
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
        #expect((given["skipPermissions"]) == nil, "a job that doesn't say has none in AGENT_JOB")
        #expect(environment["AGENT_TOKEN"] == nil, "a job with no token gives none")

        job.token = "t0k3n"
        job.skipPermissions = true
        let tokened = await runner.environment(for: job)
        #expect(tokened["AGENT_TOKEN"] == "t0k3n", "the token in AGENT_TOKEN alone")
        let tokenedJob = try #require(tokened["AGENT_JOB"])
        #expect(!tokenedJob.contains("t0k3n"), "never in AGENT_JOB")
        let acting = try #require(JSONSerialization.jsonObject(with: Data(tokenedJob.utf8)) as? [String: Any])
        #expect((acting["skipPermissions"] as? Bool) == true)
        #expect(NativeRunner.metadata(job)[stringValues: "authorization"].map { $0 } == ["Bearer t0k3n"], "its renewals and releases show it")
        #expect(NativeRunner.metadata(job, runnerToken: "r1")[stringValues: "authorization"].map { $0 } == ["Bearer t0k3n", "Bearer r1"],
                "and the runner's own token beside it")
        #expect(NativeRunner.metadata(runnerToken: "r1")[stringValues: "authorization"].map { $0 } == ["Bearer r1"], "its claims show its own")
        #expect(NativeRunner.metadata()[stringValues: "authorization"].map { $0 }.isEmpty)

        // A manual session's job, as Visor's dispatcher gives it out: false, said.
        let jobs = queue()
        var manual = start("Manual")
        manual.skipPermissions = false
        _ = try jobs.queueStart(manual).get()
        let claimed = try #require(await jobs.claim(claim(), wait: .zero))
        let manualJob = try #require(await runner.environment(for: claimed)["AGENT_JOB"])
        #expect(manualJob.contains("\"skipPermissions\":false"), Comment(rawValue: manualJob))
    }

    /// Each agent's own token (Job.token): a JWT for `visor.runner-agent`,
    /// its `sub` the session it carries on and its `agent` its own id,
    /// minted for an hour when its job is claimed; the agent's alone, with
    /// no table of them kept; and refused once its job is gone.
    @Test func eachAgentHasATokenOfItsOwn() async throws {
        let secrets = MemorySecrets()
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let jobs = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", tokens: tokens, log: { _ in })
        let a = try jobs.queueStart(start("A")).get()
        #expect(jobs.queueResume(AgentJobMove(agent: "b1", session: "s-b", title: "B", resume: "c-b", cwd: "/tmp", runsOn: "native")) == .success("s-b"))
        let first = await jobs.claim(claim(), wait: .zero)
        let second = await jobs.claim(claim(), wait: .zero)
        let jobA = try #require(first)
        let jobB = try #require(second)
        #expect(jobA.agent.uuid == a && jobB.agent.uuid == "b1")
        #expect(JWT.isShaped(jobA.token) && JWT.isShaped(jobB.token) && jobA.token != jobB.token)
        let claimsA = try tokens.verify(jobA.token, as: .runnerAgent, agent: a).get()
        #expect(claimsA.iss == "server-1" && claimsA.aud == "visor.runner-agent" && claimsA.sub == a && claimsA.agent == a)
        #expect(claimsA.scope == ["messages", "approvals", "mcp", "job"])
        #expect(claimsA.exp - claimsA.iat == 3600, "an hour")
        let claimsB = try tokens.verify(jobB.token, as: .runnerAgent, agent: "b1").get()
        #expect(claimsB.sub == "s-b" && claimsB.agent == "b1", "a moved session's agent acts as its session")
        #expect(jobs.access(a, bearer: jobA.token) == .granted)
        #expect(jobs.access(a.uppercased(), bearer: jobA.token) == .granted, "however the agent's id is spelt")
        #expect(jobs.access(a, bearer: nil) == .refused("The call shows no token (authorization: Bearer <Job.token>)."))
        #expect(jobs.access(a, bearer: jobB.token) == .refused("That token is another agent's."))
        #expect(jobs.access(a, bearer: "guess") == .refused("That token isn't this agent's."))
        #expect(jobs.access(a, bearer: String(jobA.token.dropLast())) == .refused("That token isn't this agent's."), "its signature cut")
        #expect(jobs.access(a, bearers: ["guess", jobA.token]) == .granted, "among others shown")
        #expect(jobs.access("nobody", bearer: jobA.token) == .unknown)
        #expect(secrets.get("runnerAgentTokens") == nil, "no table kept")
        #expect(!jobs.stored.claimed.contains { "\($0)".contains(jobA.token) }, "never in jobs.json")

        // A session's token (not a runner's agent's) is refused here.
        #expect(jobs.access(a, bearer: tokens.mint(.session, session: a)) == .refused(AgentTokenRefusal.wrongAudience.message))
        // Another server's is refused.
        let other = AgentTokens(secrets: MemorySecrets(), issuer: "server-2")
        #expect(jobs.access(a, bearer: other.mint(.runnerAgent, session: a, agent: a)) != .granted)

        // Expired: refused on the driver, taken on a runner's Renew and
        // Release within its grace, and no longer.
        let old = tokens.mint(.runnerAgent, session: a, agent: a, now: Date().addingTimeInterval(-7200))
        #expect(jobs.access(a, bearer: old) == .expired)
        #expect(jobs.access(a, bearer: old, withinGrace: true) == .granted)
        let ancient = tokens.mint(.runnerAgent, session: a, agent: a, now: Date().addingTimeInterval(-3600 - AgentTokens.expiredTokenGrace - 60))
        #expect(jobs.access(a, bearer: ancient, withinGrace: true) == .expired, "past its grace")
        #expect(jobs.access(a, bearer: old, withinGrace: true, now: Date().addingTimeInterval(AgentTokens.expiredTokenGrace)) == .expired,
                "its grace runs out")

        // An archived session's agent is refused.
        jobs.liveSession = { $0 == a ? false : nil }
        #expect(jobs.access(a, bearer: jobA.token) == .refused(AgentTokenRefusal.archived.message))
        jobs.liveSession = nil

        // A requeued job's claim mints a fresh one, the same agent's.
        jobs.report(.with { $0.agent = jobB.agent; $0.released = .with { $0.reason = "its runner restarted" } })
        let requeued = try #require(await jobs.claim(claim(), wait: .zero))
        #expect(requeued.token != jobB.token)
        #expect(jobs.access("b1", bearer: requeued.token) == .granted)
        #expect(jobs.access("b1", bearer: jobB.token) == .granted, "and the one before, until it ends")

        // Gone with its job: an ended session's, a stopped agent's.
        jobs.forget(session: a)
        #expect(jobs.access(a, bearer: jobA.token) == .unknown)
        jobs.stopJobs(of: "s-b")
        #expect(jobs.access("b1", bearer: requeued.token) == .unknown)
    }

    /// Job.skip_permissions: a started job's from its request (asking when
    /// it says nothing), a moved session's from its move (the session's).
    @Test func aJobSaysWhetherItsAgentAsks() async throws {
        let jobs = queue()
        var acting = start("Acts")
        acting.skipPermissions = true
        _ = try jobs.queueStart(acting).get()
        _ = try jobs.queueStart(start("Asks")).get()
        var manual = start("Manual")
        manual.skipPermissions = false
        _ = try jobs.queueStart(manual).get()
        // Said either way, false included: Job.skip_permissions has
        // presence, and a job without it reads as an old dispatcher's,
        // whose runner passes --skip-permissions.
        for (title, skips) in [("Acts", true), ("Asks", false), ("Manual", false)] {
            let job = try #require(await jobs.claim(claim(), wait: .zero))
            #expect(job.title == title)
            #expect(job.hasSkipPermissions, "\(title): said")
            #expect(job.skipPermissions == skips, "\(title)")
        }
        var move = AgentJobMove(session: "s-m", title: "M", resume: "c-m", cwd: "/tmp", runsOn: "native")
        move.skipPermissions = true
        let skip = jobs.resumeJob(move, agent: "m1")
        #expect(skip.hasSkipPermissions && skip.skipPermissions)
        move.skipPermissions = false
        let asks = jobs.resumeJob(move, agent: "m1")
        #expect(asks.hasSkipPermissions && !asks.skipPermissions)

        // A moved session's job (queueResume), as claimed.
        #expect(jobs.queueResume(move) == .success("s-m"))
        let resumed = try #require(await jobs.claim(claim(), wait: .zero))
        #expect(resumed.hasSkipPermissions && !resumed.skipPermissions)
    }

    /// Job.skip_permissions across a restart (jobs.json): a waiting job and
    /// a claimed one come back saying what they said, false included.
    @Test func aRestartedQueueKeepsWhetherItsJobsAsk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", file: file, log: { _ in })
        var acting = start("Acts")
        acting.skipPermissions = true
        _ = try before.queueStart(acting).get()
        let claimed = try #require(await before.claim(claim(), wait: .zero))
        var manual = start("Manual")
        manual.skipPermissions = false
        _ = try before.queueStart(manual).get()

        let after = JobQueue(dispatcherURL: "http://127.0.0.1:7434", driverURL: "http://127.0.0.1:7434", file: file, log: { _ in })
        let held = try #require(after.claimed[claimed.agent.uuid]?.job)
        #expect(held.hasSkipPermissions && held.skipPermissions)
        let waiting = try #require(after.waiting.first)
        #expect(waiting.title == "Manual")
        #expect(waiting.hasSkipPermissions, "false kept, not dropped")
        #expect(!waiting.skipPermissions)
    }
}
