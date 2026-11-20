// Super Compact, from a session's menu (docs/super-compact.md): its
// server condenses the session's conversation into HANDOFF.md, a job that
// runs for minutes to hours on the server whatever this device does; this
// follows it while the sheet is open, shows HANDOFF.md for the person to
// review and edit, and, only once they choose Start New Session, has the
// server carry the session on from it (the cut-over). Review is required:
// nothing is cut over on its own.

import Observation
import VisorProtocol

@MainActor
@Observable
public final class SuperCompact: Identifiable {
    public enum Stage: Equatable {
        /// Asking the server how the session's job stands.
        case loading
        /// No job waits on the person: one can be started (`status` is the
        /// last one's, if it failed or was cancelled).
        case ready
        /// The job runs on the server: its progress in `status`.
        case running
        /// Done: HANDOFF.md in `handoff`, for the person to review.
        case review
        /// The new session being started from it.
        case cuttingOver
        /// Carried on as the session with this id; the old one archived.
        case continued(String)
    }

    public nonisolated let id: String
    public let session: SessionInfo
    public let host: AgentServerConnection
    public private(set) var stage: Stage = .loading
    /// The session's job, as the server last told it.
    public private(set) var status: SuperCompactStatus?
    /// HANDOFF.md, as the server has it (with the person's saved edits).
    public private(set) var handoff = ""
    /// A step that failed, in the server's words; the stage is unchanged.
    public private(set) var problem: String?
    /// A step under way (a start, a cancel, a save): its buttons wait.
    public private(set) var working = false
    /// What the server said of the cut-over: the memory copied, the mail moved.
    public private(set) var cutoverWords: String?

    @ObservationIgnored private var following = false

    /// How often a running job is asked after, in milliseconds.
    static let pollInterval: Int32 = 2_000

    public init(session: SessionInfo, host: AgentServerConnection) {
        id = host.id + "|" + session.id + "|super-compact"
        self.session = session
        self.host = host
    }

    /// The title of the session it was carried on as, once there is one.
    public var continuedTitle: String? {
        guard case .continued(let next) = stage else { return nil }
        return host.sessions.first { $0.id == next }?.title
    }

    /// How the session's job stands, and its handoff once it is done.
    public func load() async {
        do {
            take(try await host.server.superCompact(of: session.id))
            if stage == .review { handoff = try await host.server.superCompactHandoff(of: session.id) }
            problem = nil
        } catch {
            if stage == .loading { stage = .ready }
            problem = Self.words(error)
        }
    }

    /// Follows a running job until it ends or `isFollowing` says stop (the
    /// sheet closed): its progress, then its handoff.
    public func follow(while isFollowing: @escaping @MainActor () -> Bool) async {
        // One follower at a time, however often it is asked.
        guard !following else { return }
        following = true
        defer { following = false }
        while isFollowing(), stage == .running {
            await host.server.delay(milliseconds: Self.pollInterval)
            guard isFollowing(), stage == .running else { return }
            await load()
        }
    }

    /// Starts the job (or carries a failed one on).
    public func start() async {
        await step { take(try await host.server.startSuperCompact(session.id)) }
    }

    /// Cancels the running job: it is over for good.
    public func cancel() async {
        await step { take(try await host.server.cancelSuperCompact(session.id)) }
    }

    /// The handoff thrown away: nothing is cut over, and a new job can be started.
    public func discard() async {
        await step { take(try await host.server.cancelSuperCompact(session.id)) }
    }

    /// The person's edits saved as HANDOFF.md: whether they were.
    public func save(_ text: String) async -> Bool {
        var saved = false
        await step {
            let status = try await host.server.saveSuperCompactHandoff(of: session.id, text: text)
            handoff = text
            take(status)
            saved = true
        }
        return saved
    }

    /// The cut-over, once the person has reviewed HANDOFF.md: the new
    /// session's id, listed at once, or nil when the server refused.
    public func cutOver() async -> String? {
        guard stage == .review else { return nil }
        stage = .cuttingOver
        working = true
        defer { working = false }
        do {
            let (next, sessions) = try await host.server.superCompactCutover(session.id)
            if !sessions.isEmpty { host.take(sessions, replacing: true) }
            problem = nil
            stage = .continued(next)
            return next
        } catch {
            stage = .review
            problem = Self.words(error)
            return nil
        }
    }

    /// One step, its buttons waiting until it is done; its refusal kept.
    private func step(_ run: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await run()
            problem = nil
            if stage == .review, handoff.isEmpty { handoff = try await host.server.superCompactHandoff(of: session.id) }
        } catch {
            problem = Self.words(error)
        }
    }

    /// The stage the server's word on the job puts the sheet in.
    private func take(_ status: SuperCompactStatus?) {
        self.status = status
        guard let status else {
            stage = .ready
            return
        }
        if let next = status.continuedAs {
            stage = .continued(next)
        } else if !status.phase.ended {
            stage = .running
        } else if status.awaitsReview {
            stage = .review
        } else {
            stage = .ready
            handoff = ""
        }
    }

    private static func words(_ error: Error) -> String {
        if case AgentServerError.message(let text) = error { return text }
        if case AgentServerError.unsupported = error { return "This computer doesn't do Super Compact: update its Visor Server." }
        return "\(error)"
    }
}
