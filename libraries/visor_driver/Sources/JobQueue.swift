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
    /// The harness jobs run ("claude"; "echo" for a test without a model).
    let harness: String
    private let log: @Sendable (String) -> Void

    private(set) var waiting: [AgentProtocol_V1_Job] = []
    /// Claimed jobs by agent id, with their runner and expiry.
    private(set) var claimed: [String: (job: AgentProtocol_V1_Job, runner: String, expires: Date)] = [:]
    private var pollers: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(dispatcherURL: String, driverURL: String, harness: String = "claude",
         log: @escaping @Sendable (String) -> Void = { VisorServer.log($0) }) {
        self.dispatcherURL = dispatcherURL
        self.driverURL = driverURL
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
                return job
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
        guard let held = claimed[agent.uuid] else { return nil }
        let expires = Date().addingTimeInterval(Self.claimLength)
        claimed[agent.uuid] = (held.job, held.runner, expires)
        return expires
    }

    /// How a claimed job goes: done (completed, failed) lets it go; released
    /// puts it back at the front of the queue.
    func report(_ report: AgentProtocol_V1_JobReport) {
        let id = report.agent.uuid
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
