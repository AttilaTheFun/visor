// One Super Compact job running (docs/super-compact.md): the prefilter,
// then the cascade — the map (Haiku) a chunk at a time with the ledger
// carried forward, the merge (Sonnet) in groups and groups of groups, the
// final step (Opus) writing HANDOFF.md — then the check. Every step's
// output is a file in the job's folder, written once it is whole, and the
// job's state is kept after each (SuperCompactJob), so a restart carries
// on from the last step finished (SuperCompaction+Steps). The server runs
// one at a time (VisorServer+SuperCompact).

import Foundation
import Synchronization
import VisorSystem

@MainActor
final class SuperCompaction {
    private(set) var job: SuperCompactJob
    /// The `claude` it runs.
    let tool: String
    /// The session's folder, for HANDOFF.md to name.
    let cwd: String
    let stop = Stop()
    /// How long one call may take before it is ended and tried again.
    var callLimit: Duration = .seconds(60 * 60)
    /// How many times a call is tried before the job fails.
    var attempts = 3
    /// Told when it has ended: done, failed, cancelled or halted.
    var onEnd: ((SuperCompactJob) -> Void)?
    private var task: Task<Void, Never>?

    init(job: SuperCompactJob, tool: String, cwd: String) {
        self.job = job
        self.tool = tool
        self.cwd = cwd
    }

    /// Why it was asked to stop: cancelled (it ends so, for good), or
    /// halted (the server is going away: it is left as it stands, to carry
    /// on when the server is back).
    enum StopReason: Sendable { case cancelled, halted }

    /// Asked from the threads that read and call: whether to stop, and why.
    final class Stop: Sendable {
        private let reason = Mutex<StopReason?>(nil)
        var asked: StopReason? { reason.withLock { $0 } }
        var isSet: Bool { asked != nil }
        func set(_ value: StopReason) { reason.withLock { if $0 == nil { $0 = value } } }
    }

    /// Why a step could not go on.
    enum Failure: Error {
        case stopped
        case failed(String)
    }

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    /// Ends it for good: the call under way is ended, and it is cancelled.
    func cancel() {
        guard !job.phase.ended else { return }
        stop.set(.cancelled)
        job.failedIn = job.phase
        job.phase = .cancelled
        job.finished = Date().timeIntervalSince1970
        save()
    }

    /// Stops it where it stands (the server is going away): kept as it
    /// is, to carry on from its last finished step.
    func halt() { stop.set(.halted) }

    /// Waits for it to have stopped (tests).
    func ended() async { await task?.value }

    func save() {
        job.updated = Date().timeIntervalSince1970
        job.keep()
    }

    func update(_ change: (inout SuperCompactJob) -> Void) {
        change(&job)
        save()
    }

    private func run() async {
        VisorServer.log("super compact \(job.id) of \(job.session): \(job.phase.rawValue)")
        do {
            if job.phase == .prefilter { try await prefilter() }
            if job.phase == .map { try await map() }
            if job.phase == .merge { try await merge() }
            if job.phase == .final { try await final() }
        } catch {
            switch stop.asked {
            case .cancelled: break
            case .halted: VisorServer.log("super compact \(job.id): halted in \(job.phase.rawValue), to carry on later")
            case nil:
                var reason = "\(error)"
                if let failure = error as? Failure, case .failed(let why) = failure { reason = why }
                VisorServer.log("super compact \(job.id) failed in \(job.phase.rawValue): \(reason)")
                update {
                    $0.failedIn = $0.phase
                    $0.phase = .failed
                    $0.error = reason
                    $0.finished = Date().timeIntervalSince1970
                }
            }
        }
        if job.phase == .done { VisorServer.log("super compact \(job.id) done: \(job.handoff ?? "")") }
        onEnd?(job)
    }
}
