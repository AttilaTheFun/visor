// The jobs runners pull from Visor's server (agent_protocol's
// AgentDispatcher): queued by clients (`POST /api/jobs`), claimed by a
// runner that can run their harness, kept while it renews the claim, and
// back at the front of the queue when it is released or lapses. Each job's
// agent is driven by this server: its wrapper dials `driverURL`, and its
// session appears as it does.

import AgentProtocol
import Foundation
import VisorProtocol
import VisorServer

@MainActor
final class JobQueue: AgentJobQueue {
    /// How long a claim holds without a renewal.
    static let claimLength: TimeInterval = 60

    /// This dispatcher's address, as runners reach it (in an agent's id).
    let dispatcherURL: String
    /// The driver the jobs' wrappers dial (this server's).
    let driverURL: String
    /// This server's driver and dispatcher as a container reaches them
    /// (through MultiPass's dial-in: `http://visor.multipass.internal:7434`),
    /// given to a runner whose capabilities say `container` in place of
    /// both; nil, and containers are given the same addresses as the rest.
    let containerURL: String?
    /// The harness jobs run ("claude"; "echo" for a test without a model).
    let harness: String
    private let log: @Sendable (String) -> Void

    private(set) var waiting: [AgentProtocol_V1_Job] = []
    /// The sessions moved to runners, by agent id: the conversation each
    /// carries on and where it worked here, for the driver's Conversation.
    private(set) var moves: [String: (resume: String, cwd: String)] = [:]
    /// The session each moved agent carries on, by agent id. An agent's id
    /// is a UUID (agent_protocol's AgentID, which runners hold to); a
    /// session's isn't, so a move's job is a new agent of the session's.
    private(set) var movedSessions: [String: String] = [:]
    /// How many times each agent's job has come back from a runner without
    /// its agent saying how it went: one that ends at once every time goes
    /// after `attempts`, not round and round.
    private(set) var returns: [String: Int] = [:]
    /// How many times a job is given out before one that keeps coming back
    /// unexplained is given up.
    static let attempts = 3
    /// Claimed jobs by agent id, with their runner and expiry.
    private(set) var claimed: [String: (job: AgentProtocol_V1_Job, runner: String, expires: Date)] = [:]
    private var pollers: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(dispatcherURL: String, driverURL: String, containerURL: String? = nil, harness: String = "claude",
         log: @escaping @Sendable (String) -> Void = { VisorServer.log($0) }) {
        self.dispatcherURL = dispatcherURL
        self.driverURL = driverURL
        self.containerURL = containerURL.flatMap { $0.isEmpty ? nil : $0 }
        self.harness = harness
        self.log = log
    }

    func queueStart(_ request: Envelope) -> Result<String, AgentJobRefusal> {
        let agent = request.agent ?? .claude
        guard agent == .claude else { return .failure(AgentJobRefusal("Runners run Claude Code agents for now.")) }
        let title = (request.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var job = AgentProtocol_V1_Job()
        job.agent.uuid = UUID().uuidString.lowercased()
        job.agent.dispatcherURL = dispatcherURL
        job.harness = harness
        job.title = title.isEmpty ? agent.title : String(title.prefix(60))
        job.workingDirectory = request.cwd ?? ""
        job.model = request.model ?? ""
        job.effort = request.effort ?? ""
        job.prompt = request.text ?? ""
        job.driverURL = driverURL
        if let kind = request.runsOn?.trimmingCharacters(in: .whitespaces), !kind.isEmpty {
            job.labels.append(Self.runsOn + kind)
        }
        waiting.append(job)
        log("dispatcher: queued \(job.agent.uuid) (\(job.title))")
        wake()
        return .success(job.agent.uuid)
    }

    func queueResume(_ move: AgentJobMove) -> Result<String, AgentJobRefusal> {
        let session = Self.key(move.session)
        guard !session.isEmpty, !move.resume.isEmpty else { return .failure(AgentJobRefusal("The session has no conversation to carry on.")) }
        let agents = movedSessions.filter { $0.value == session }.keys
        guard !agents.contains(where: { agent in waiting.contains { $0.agent.uuid == agent } || claimed[agent] != nil }) else {
            return .failure(AgentJobRefusal("The session is moving to a runner already."))
        }
        let id = UUID().uuidString.lowercased()
        var job = AgentProtocol_V1_Job()
        job.agent.uuid = id
        job.agent.dispatcherURL = dispatcherURL
        job.harness = harness
        job.title = move.title
        job.model = move.model
        job.effort = move.effort
        job.driverURL = driverURL
        job.resumeSessionID = move.resume
        job.sources = move.sources.map { source in .with { $0.repository = source.repository; $0.ref = source.ref; $0.name = source.name } }
        if !move.runsOn.isEmpty { job.labels.append(Self.runsOn + move.runsOn) }
        moves[id] = (move.resume, move.cwd)
        movedSessions[id] = session
        waiting.append(job)
        log("dispatcher: queued \(id) for \(session) (\(job.title)), carrying on \(move.resume) on a \(move.runsOn.isEmpty ? "any" : move.runsOn) runner")
        wake()
        return .success(session)
    }

    func forget(session: String) {
        let session = Self.key(session)
        let agents = Set(movedSessions.filter { $0.value == session }.keys).union([session])
        let dropped = waiting.filter { agents.contains($0.agent.uuid) }.count + claimed.keys.filter(agents.contains).count
        for agent in agents { forget(agent: agent) }
        if dropped > 0 { log("dispatcher: \(session) ended: its job dropped") }
    }

    /// An agent's job gone, waiting or claimed (its runner's next renewal
    /// is refused), and what was kept for it.
    private func forget(agent: String) {
        waiting.removeAll { $0.agent.uuid == agent }
        claimed[agent] = nil
        moves[agent] = nil
        movedSessions[agent] = nil
        returns[agent] = nil
    }

    /// The session an agent is: a moved session's, else the agent's own id
    /// (a job started here is a session of that id).
    func session(of agent: String) -> String {
        let id = Self.key(agent)
        return movedSessions[id] ?? id
    }

    /// The conversation a moved session carries on, and where it was here.
    func move(of agent: AgentProtocol_V1_AgentID) -> (resume: String, cwd: String)? {
        moves[Self.key(agent.uuid)]
    }

    /// A job for `runner`, now or within `wait`: claimed by it.
    func claim(_ request: AgentProtocol_V1_ClaimRequest, wait: Duration) async -> AgentProtocol_V1_Job? {
        let deadline = ContinuousClock.now + wait
        while true {
            releaseLapsed()
            if let index = waiting.firstIndex(where: { Self.takes(request.capabilities, $0) }) {
                var job = waiting.remove(at: index)
                let expires = Date().addingTimeInterval(Self.claimLength)
                job.claimExpires = .init(date: expires)
                claimed[job.agent.uuid] = (job, request.runner, expires)
                log("dispatcher: \(request.runner) claimed \(job.agent.uuid)")
                return addressed(job, for: request.capabilities)
            }
            let left = deadline - .now
            guard left > .zero else { return nil }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: left) }
                group.addTask { await self.nextQueued() }
                await group.next()
                group.cancelAll()
            }
            if Task.isCancelled { return nil }
        }
    }

    /// A claim kept: its new expiry, or nil when it isn't held any more.
    func renew(_ agent: AgentProtocol_V1_AgentID) -> Date? {
        let id = Self.key(agent.uuid)
        guard let held = claimed[id] else { return nil }
        let expires = Date().addingTimeInterval(Self.claimLength)
        claimed[id] = (held.job, held.runner, expires)
        return expires
    }

    /// How a claimed job goes: done (completed, failed) lets it go; released
    /// puts it back at the front of the queue.
    func report(_ report: AgentProtocol_V1_JobReport) {
        let id = Self.key(report.agent.uuid)
        switch report.event {
        case .started(let started):
            log("dispatcher: \(id) started by \(started.runner) (session \(started.sessionID))")
        case .progress(let progress):
            log("dispatcher: \(id): \(progress.text)")
        case .blocked(let blocked):
            log("dispatcher: \(id) blocked: \(blocked.reason)")
        case .completed(let completed):
            claimed[id] = nil
            log("dispatcher: \(id) completed\(completed.summary.isEmpty ? "" : ": \(completed.summary.prefix(120))")")
        case .failed(let failed):
            claimed[id] = nil
            log("dispatcher: \(id) failed: \(failed.reason)")
        case .released(let released):
            requeue(id, why: "released: \(released.reason)")
        case .none:
            break
        }
    }

    /// `job` as `capabilities`' runner is given it: a container's, this
    /// server's addresses as containers reach them. The job kept (and
    /// queued again if released) keeps its own.
    func addressed(_ job: AgentProtocol_V1_Job, for capabilities: [String]) -> AgentProtocol_V1_Job {
        guard let containerURL, capabilities.contains(Self.container) else { return job }
        var given = job
        given.agent.dispatcherURL = containerURL
        given.driverURL = containerURL
        return given
    }

    /// The capability of a runner that runs its agents in containers.
    static let container = "container"

    /// An agent's id as this dispatcher keys it: the UUID it issued, in
    /// lower case, however a runner or wrapper spells it back (Foundation's
    /// `UUID.uuidString` is upper case).
    nonisolated static func key(_ uuid: String) -> String {
        uuid.lowercased()
    }

    /// The label a job that asks for a kind of runner carries:
    /// `runs-on:native` goes only to a runner whose capabilities say
    /// `native`.
    static let runsOn = "runs-on:"

    /// Whether a runner with these capabilities runs `job`: its harness,
    /// and the kind of runner it asks for, if any.
    static func takes(_ capabilities: [String], _ job: AgentProtocol_V1_Job) -> Bool {
        let kinds = job.labels.filter { $0.hasPrefix(runsOn) }.map { String($0.dropFirst(runsOn.count)) }
        guard kinds.allSatisfy(capabilities.contains) else { return false }
        return job.harness.isEmpty || capabilities.contains("harness:\(job.harness)")
    }

    /// Claims not renewed in time, released.
    private func releaseLapsed(now: Date = Date()) {
        for (id, held) in claimed where held.expires < now { requeue(id, why: "its claim lapsed") }
    }

    private func requeue(_ id: String, why: String) {
        guard let held = claimed.removeValue(forKey: id) else { return }
        let returned = (returns[id] ?? 0) + 1
        returns[id] = returned
        guard returned < Self.attempts else {
            forget(agent: id)
            log("dispatcher: \(id) \(why): given up after \(returned) tries")
            return
        }
        var job = held.job
        job.clearClaimExpires()
        waiting.insert(job, at: 0)
        log("dispatcher: \(id) \(why): queued again")
        wake()
    }

    private func nextQueued() async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { pollers[key] = $0 }
        } onCancel: {
            Task { @MainActor in self.resume(key) }
        }
    }

    private func resume(_ key: UUID) {
        pollers.removeValue(forKey: key)?.resume()
    }

    private func wake() {
        let waking = pollers
        pollers = [:]
        for continuation in waking.values { continuation.resume() }
    }
}
