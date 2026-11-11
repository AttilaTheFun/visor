// A start waiting in the server's queue (docs/runners.md, "The queue"): what
// to start, for which runner, and how far it has got. Its id becomes the
// session's.

import Foundation

/// A start in the server's queue.
public struct QueueEntry: Codable, Hashable, Sendable {
    /// How far a start has got.
    public enum State: String, Codable, Hashable, Sendable {
        /// No runner that matches has room yet.
        case waiting
        /// Given to a runner, its agent not yet dialed in.
        case starting
        /// Its agent said hello: the entry is done.
        case running
        /// The runner couldn't start it (`problem`).
        case failed
    }

    /// When the session is archived on its own.
    public enum ArchiveWhen: String, Codable, Hashable, Sendable {
        /// Only by hand.
        case never
        /// When its agent reports complete (an agent job).
        case complete
    }

    /// The session's id to be.
    public var id: String
    public var agent: AgentKind
    public var title: String
    public var prompt: String?
    public var repository: String?
    public var branch: String?
    public var cwd: String?
    /// The runner asked for by id; else any whose labels include all of
    /// `labels`.
    public var runner: String?
    public var labels: [String]
    public var links: [String]
    public var archiveWhen: ArchiveWhen
    /// Who queued it: a client's user, or a runner's id.
    public var createdBy: String
    public var created: Date
    public var state: State
    /// Why it failed.
    public var problem: String?

    public init(id: String, agent: AgentKind, title: String, prompt: String? = nil, repository: String? = nil, branch: String? = nil,
                cwd: String? = nil, runner: String? = nil, labels: [String] = [], links: [String] = [], archiveWhen: ArchiveWhen = .never,
                createdBy: String, created: Date, state: State = .waiting, problem: String? = nil) {
        self.id = id
        self.agent = agent
        self.title = title
        self.prompt = prompt
        self.repository = repository
        self.branch = branch
        self.cwd = cwd
        self.runner = runner
        self.labels = labels
        self.links = links
        self.archiveWhen = archiveWhen
        self.createdBy = createdBy
        self.created = created
        self.state = state
        self.problem = problem
    }

    /// Whether a runner can take it: the one asked for, or one with every
    /// label asked for, that runs this agent and has room.
    public func fits(_ runner: RunnerHello) -> Bool {
        guard runner.capacity > 0, runner.agents.contains(agent) else { return false }
        if let wanted = self.runner { return wanted == runner.id }
        return Set(labels).isSubset(of: Set(runner.labels))
    }
}
