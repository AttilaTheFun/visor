// A start the server gives a runner from its queue (docs/runners.md, "A
// runner"): which session, of which agent, where, and with what to begin.
// It carries no sign-in: the agent gets those over its own connection.

/// What a runner is asked to start.
public struct RunnerStart: Codable, Hashable, Sendable {
    /// The session's id: a new one, or an archived one's, to resume.
    public var session: String
    /// A one-time token for the session's agent, which MultiPass checks when
    /// the agent dials in.
    public var agentToken: String
    public var agent: AgentKind
    /// The repository to clone (`owner/name`) and its branch, for a runner
    /// that clones (#345); or a folder, for a native one.
    public var repository: String?
    public var branch: String?
    public var cwd: String?
    /// The first message, if any.
    public var prompt: String?
    public var title: String
    public var links: [String]
    /// The agent's own conversation to go on with, for a resumed session.
    public var resume: String?

    public init(session: String, agentToken: String, agent: AgentKind, repository: String? = nil, branch: String? = nil,
                cwd: String? = nil, prompt: String? = nil, title: String, links: [String] = [], resume: String? = nil) {
        self.session = session
        self.agentToken = agentToken
        self.agent = agent
        self.repository = repository
        self.branch = branch
        self.cwd = cwd
        self.prompt = prompt
        self.title = title
        self.links = links
        self.resume = resume
    }
}
