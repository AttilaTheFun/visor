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
    /// (through Shireworks' agent-proxy: `http://visor.agent.internal:7434`),
    /// given to a runner whose capabilities say `container` in place of
    /// both; nil, and containers are given the same addresses as the rest.
    let containerURL: String?
    /// The harness jobs run ("claude"; "echo" for a test without a model).
    let harness: String
    let log: @Sendable (String) -> Void
    /// Where the jobs are kept across a restart (JobQueue+Store); nil: in
    /// memory alone.
    let file: URL?
    /// Where the agents' tokens are kept across a restart (the server's
    /// secrets: JobQueue+Tokens); nil: in memory alone.
    let secrets: (any SecretStore)?
    /// Each agent's token (Job.token), by agent id (JobQueue+Tokens).
    var tokens: [String: String] = [:]

    var waiting: [AgentProtocol_V1_Job] = []
    /// The sessions moved to runners, by agent id: the conversation each
    /// carries on and where it worked here, for the driver's Conversation.
    var moves: [String: (resume: String, cwd: String)] = [:]
    /// The session each moved agent carries on, by agent id. An agent's id
    /// is a UUID (agent_protocol's AgentID, which runners hold to); a
    /// session's isn't, so a move's job is a new agent of the session's.
    var movedSessions: [String: String] = [:]
    /// How many times each agent's job has come back from a runner without
    /// its agent saying how it went, since it last started: one that ends at
    /// once every time goes after `attempts`, not round and round. A start
    /// clears it: an agent that ran, and comes back because its runner
    /// restarted, is no failure (13 Nov: a session moved back after its
    /// third runner restart).
    var returns: [String: Int] = [:]
    /// How many times a job is given out before one that keeps coming back
    /// unexplained is given up.
    static let attempts = 3
    /// Claimed jobs by agent id, with their runner and expiry.
    var claimed: [String: (job: AgentProtocol_V1_Job, runner: String, expires: Date)] = [:]
    /// Claims taken up when this server started (from jobs.json, or from a
    /// driven session's move in sessions.json: adopt), until their runner
    /// renews one or its agent starts again: a lapse or a release of one
    /// is this server's restart, not an agent that failed to start, and
    /// isn't counted toward `attempts` (JobQueue+Restart).
    var restored: Set<String> = []
    /// How long a claim taken up at a start holds before its runner renews
    /// it: its renewals, and its wrapper's redial (with backoff), have this
    /// long to come back before its job is given out again (and its session
    /// told so: moveRequeued).
    static let redialGrace: TimeInterval = 180
    private var pollers: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// A move whose job failed or was given up: its session, the
    /// conversation it carries on, where it worked here, and why (the
    /// server brings it back: VisorServer.moveBack).
    var moveFailed: (@MainActor (_ session: String, _ resume: String, _ cwd: String, _ why: String) -> Void)?
    /// A moved session's agent started on its runner: the harness's own
    /// session there (Started's), which a later agent resumes.
    var moveStarted: (@MainActor (_ session: String, _ agent: String, _ conversation: String) -> Void)?
    /// A moved session's job given out again because its runner's agent
    /// didn't come back after this server restarted, and why.
    var moveRequeued: (@MainActor (_ session: String, _ why: String) -> Void)?

    /// `file`: where the jobs are kept, and taken up from at start;
    /// `secrets`: where the agents' tokens are.
    init(dispatcherURL: String, driverURL: String, containerURL: String? = nil, harness: String = "claude", file: URL? = nil,
         secrets: (any SecretStore)? = nil, log: @escaping @Sendable (String) -> Void = { VisorServer.log($0) }) {
        self.dispatcherURL = dispatcherURL
        self.driverURL = driverURL
        self.containerURL = containerURL.flatMap { $0.isEmpty ? nil : $0 }
        self.harness = harness
        self.file = file
        self.secrets = secrets
        self.log = log
        tokens = Self.keptTokens(secrets)
        guard let kept = Self.read(file) else { return }
        waiting = kept.waiting.map(\.job)
        // Long enough for the runner, and the wrapper redialling, to find
        // this server again; restored, so their going isn't a failed start.
        let expires = Date().addingTimeInterval(Self.redialGrace)
        for claim in kept.claimed {
            var job = claim.job.job
            job.claimExpires = .init(date: expires)
            claimed[claim.job.uuid] = (job, claim.runner, expires)
            restored.insert(claim.job.uuid)
        }
        for move in kept.moves {
            moves[move.agent] = (move.resume, move.cwd)
            movedSessions[move.agent] = move.session
        }
        returns = kept.returns
        log("dispatcher: \(waiting.count) waiting, \(claimed.count) claimed and \(movedSessions.count) moved sessions taken up from \(file?.lastPathComponent ?? "")")
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
        // Asks before acting unless the request says otherwise: the
        // session it becomes takes the same (DriverService.info). Always
        // said, false included: Job.skip_permissions has presence, and a
        // job without it reads as an old dispatcher's, whose runner
        // passes --skip-permissions.
        job.skipPermissions = request.skipPermissions ?? false
        if let kind = request.runsOn?.trimmingCharacters(in: .whitespaces), !kind.isEmpty {
            job.labels.append(Self.runsOn + kind)
        }
        job.token = token(for: job.agent.uuid)
        waiting.append(job)
        log("dispatcher: queued \(job.agent.uuid) (\(job.title))")
        save()
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
        let id = move.agent.isEmpty ? UUID().uuidString.lowercased() : Self.key(move.agent)
        var job = resumeJob(move, agent: id)
        job.token = token(for: id)
        moves[id] = (move.resume, move.cwd)
        movedSessions[id] = session
        returns[id] = nil
        waiting.append(job)
        save()
        log("dispatcher: queued \(id) for \(session) (\(job.title)), carrying on \(job.resumeSessionID) on a \(move.runsOn.isEmpty ? "any" : move.runsOn) runner"
            + (move.workingDirectory.isEmpty ? "" : " in \(move.workingDirectory)"))
        wake()
        return .success(session)
    }

    func forget(session: String) {
        let session = Self.key(session)
        let agents = Set(movedSessions.filter { $0.value == session }.keys).union([session])
        let dropped = waiting.filter { agents.contains($0.agent.uuid) }.count + claimed.keys.filter(agents.contains).count
        for agent in agents { forget(agent: agent) }
        save()
        if dropped > 0 { log("dispatcher: \(session) ended: its job dropped") }
    }

    /// The job that carries `move` on as `agent`: its conversation (the
    /// runner's own, once known), in the folder its agent worked in there,
    /// with its repositories, on a runner of its kind.
    func resumeJob(_ move: AgentJobMove, agent: String) -> AgentProtocol_V1_Job {
        var job = AgentProtocol_V1_Job()
        job.agent.uuid = agent
        job.agent.dispatcherURL = dispatcherURL
        job.harness = harness
        job.title = move.title
        job.model = move.model
        job.effort = move.effort
        job.driverURL = driverURL
        job.resumeSessionID = move.resumeOnRunner
        job.workingDirectory = move.workingDirectory
        // Always said, false included (queueStart).
        job.skipPermissions = move.skipPermissions
        job.sources = move.sources.map { source in .with { $0.repository = source.repository; $0.ref = source.ref; $0.name = source.name } }
        if !move.runsOn.isEmpty { job.labels.append(Self.runsOn + move.runsOn) }
        return job
    }

    /// A moved agent that won't carry its session on: the session told to
    /// come back, and the move forgotten.
    private func endMove(of agent: String, why: String) {
        guard let session = movedSessions[agent], let move = moves[agent] else { return }
        forget(agent: agent)
        save()
        moveFailed?(session, move.resume, move.cwd, why)
    }

    /// An agent's job gone, waiting or claimed (its runner's next renewal
    /// is refused), and what was kept for it.
    func forget(agent: String) {
        waiting.removeAll { $0.agent.uuid == agent }
        claimed[agent] = nil
        moves[agent] = nil
        movedSessions[agent] = nil
        returns[agent] = nil
        restored.remove(agent)
        forgetToken(of: agent)
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
                // Its own, minted when queued (or now, for one queued by a
                // build before tokens): the runner hands it to the wrapper.
                job.token = token(for: job.agent.uuid)
                claimed[job.agent.uuid] = (job, request.runner, expires)
                save()
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
    /// One whose job was queued again meanwhile (its claim lapsed while
    /// this server restarted) is its runner's again, not given out twice.
    func renew(_ agent: AgentProtocol_V1_AgentID) -> Date? {
        let id = Self.key(agent.uuid)
        takeBack(id, why: "renewed")
        guard let held = claimed[id] else { return nil }
        let expires = Date().addingTimeInterval(Self.claimLength)
        claimed[id] = (held.job, held.runner, expires)
        restored.remove(id)
        return expires
    }

    /// How a claimed job goes: done (completed, failed) lets it go; released
    /// puts it back at the front of the queue.
    func report(_ report: AgentProtocol_V1_JobReport) {
        let id = Self.key(report.agent.uuid)
        switch report.event {
        case .started(let started):
            takeBack(id, why: "started")
            returns[id] = nil
            restored.remove(id)
            save()
            log("dispatcher: \(id) started by \(started.runner) (session \(started.sessionID))")
            if let session = movedSessions[id], !started.sessionID.isEmpty { moveStarted?(session, id, started.sessionID) }
        case .progress(let progress):
            log("dispatcher: \(id): \(progress.text)")
        case .blocked(let blocked):
            log("dispatcher: \(id) blocked: \(blocked.reason)")
        case .completed(let completed):
            claimed[id] = nil
            save()
            log("dispatcher: \(id) completed\(completed.summary.isEmpty ? "" : ": \(completed.summary.prefix(120))")")
        case .failed(let failed):
            // Only the job the session holds brings it back: an agent let
            // go (Stop Agent, a restart) failing on its way out doesn't.
            let held = claimed.removeValue(forKey: id) != nil
            restored.remove(id)
            save()
            log("dispatcher: \(id) failed: \(failed.reason)" + (held ? "" : " (its job had been let go: nothing more)"))
            if held { endMove(of: id, why: failed.reason) }
        case .released(let released):
            let counts = !restored.contains(id) && Self.mayBeStartFailure(released.reason)
            requeue(id, why: "released: \(released.reason)", counts: counts)
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

    /// Claims not renewed in time, released. One taken up at this server's
    /// start whose runner never came back is given out again, uncounted,
    /// and its session told (moveRequeued).
    func releaseLapsed(now: Date = Date()) {
        for (id, held) in claimed where held.expires < now {
            let afterRestart = restored.contains(id)
            requeue(id, why: afterRestart ? "its runner didn't renew it within \(Int(Self.redialGrace / 60)) minutes of this server's restart"
                                          : "its claim lapsed", counts: !afterRestart)
            if afterRestart, let session = movedSessions[id], waiting.contains(where: { $0.agent.uuid == id }) {
                moveRequeued?(session, "Its runner's agent didn't come back after Visor restarted: its job is queued again for a runner, "
                    + "carrying its conversation on.")
            }
        }
    }

    /// A claimed job back at the front of the queue. `counts`: as one that
    /// came back without starting (`attempts`); a release caused by this
    /// server's restart, or by the dispatcher or driver being out of reach,
    /// doesn't (mayBeStartFailure).
    func requeue(_ id: String, why: String, counts: Bool = true) {
        guard let held = claimed.removeValue(forKey: id) else {
            if waiting.contains(where: { $0.agent.uuid == id }) {
                log("dispatcher: \(id) \(why), but it is queued already")
            } else if let session = movedSessions[id] {
                log("dispatcher: \(id) (\(session)) \(why), but its job had been let go")
            } else {
                log("dispatcher: \(id) \(why), but this dispatcher holds no job of that agent")
            }
            return
        }
        restored.remove(id)
        guard counts else {
            var job = held.job
            job.clearClaimExpires()
            waiting.insert(job, at: 0)
            save()
            log("dispatcher: \(id) \(why): queued again (not counted as a failed start)")
            wake()
            return
        }
        let returned = (returns[id] ?? 0) + 1
        returns[id] = returned
        guard returned < Self.attempts else {
            log("dispatcher: \(id) \(why): given up after \(returned) tries")
            endMove(of: id, why: "its runner's agent ended \(returned) times without starting (\(why))")
            forget(agent: id)
            save()
            return
        }
        var job = held.job
        job.clearClaimExpires()
        waiting.insert(job, at: 0)
        save()
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
