// A job waiting in the server's queue for a runner (docs/runners.md, "The
// runner protocol"): a session to start, or a session's data to archive,
// copy out, start from a copy, or delete. Runners pull: each polls when it
// has room, claims an entry under a lease, and reports. An entry whose lease
// runs out goes back to the queue.

import Foundation

/// A job in the server's queue, for a runner to claim.
public struct QueueEntry: Codable, Hashable, Sendable {
    /// What the runner is to do.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Launch a wrapped agent for a new session, or an archived one's
        /// (`resume`).
        case start
        /// Stop the session's wrapper if it runs, and keep its data.
        case archive
        /// Send the session's data to the server as one archive (Migrate…,
        /// Backup…).
        case copyOut
        /// Start a session from data copied out of another runner (`copyFrom`).
        case startFromCopy
        /// Delete the session's data.
        case delete
    }

    /// How far an entry has got.
    public enum State: String, Codable, Hashable, Sendable {
        /// No runner has claimed it.
        case waiting
        /// Claimed, its lease running.
        case claimed
        /// Done: a start's agent launched, or the request carried out.
        case done
        /// The runner couldn't do it (`problem`).
        case failed
        /// Cancelled before it was claimed.
        case cancelled
    }

    /// When a started session is archived on its own.
    public enum ArchiveWhen: String, Codable, Hashable, Sendable {
        /// Only by hand.
        case never
        /// When its agent reports complete (an agent job).
        case complete
    }

    /// The entry's own id.
    public var id: String
    public var kind: Kind
    /// The session it's for: a new id for a new session.
    public var session: String
    public var agent: AgentKind
    public var title: String
    public var prompt: String?
    public var repository: String?
    public var branch: String?
    public var cwd: String?
    /// The agent's own conversation, to resume an archived session.
    public var resume: String?
    /// For startFromCopy: the copyOut entry whose data to start from.
    public var copyFrom: String?
    /// The runner asked for by id (the one holding a session's data, for
    /// all but a new start); else any whose labels include all of `labels`.
    public var runner: String?
    public var labels: [String]
    public var links: [String]
    public var archiveWhen: ArchiveWhen
    /// Who queued it: a client's user, or a runner's id.
    public var createdBy: String
    public var created: Date
    public var state: State
    /// The runner that claimed it, and when its lease runs out.
    public var claimedBy: String?
    public var leaseExpires: Date?
    /// Why it failed.
    public var problem: String?

    public init(id: String, kind: Kind = .start, session: String, agent: AgentKind, title: String, prompt: String? = nil,
                repository: String? = nil, branch: String? = nil, cwd: String? = nil, resume: String? = nil, copyFrom: String? = nil,
                runner: String? = nil, labels: [String] = [], links: [String] = [], archiveWhen: ArchiveWhen = .never,
                createdBy: String, created: Date, state: State = .waiting, claimedBy: String? = nil, leaseExpires: Date? = nil,
                problem: String? = nil) {
        self.id = id
        self.kind = kind
        self.session = session
        self.agent = agent
        self.title = title
        self.prompt = prompt
        self.repository = repository
        self.branch = branch
        self.cwd = cwd
        self.resume = resume
        self.copyFrom = copyFrom
        self.runner = runner
        self.labels = labels
        self.links = links
        self.archiveWhen = archiveWhen
        self.createdBy = createdBy
        self.created = created
        self.state = state
        self.claimedBy = claimedBy
        self.leaseExpires = leaseExpires
        self.problem = problem
    }

    /// Whether a runner polling can claim it: waiting, or claimed under a
    /// lease that has run out; and the runner it names, or one with every
    /// label, that runs this agent and has room.
    public func claimable(by runner: RunnerHello, at now: Date) -> Bool {
        let free = state == .waiting || (state == .claimed && (leaseExpires.map { $0 <= now } ?? true))
        guard free, runner.capacity > 0 || kind != .start && kind != .startFromCopy, runner.agents.contains(agent) else { return false }
        if let wanted = self.runner { return wanted == runner.id }
        return Set(labels).isSubset(of: Set(runner.labels))
    }
}
