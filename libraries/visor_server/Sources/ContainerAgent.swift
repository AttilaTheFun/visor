// A session's agent for the Sessions container to run (docs/containers.md,
// "Placing sessions"), as the container runner asks for it: who the agent
// is, the session it carries on, its job (title, harness, model, effort,
// folder, the conversation it resumes, the repositories it clones), its
// token, and what else its harness's environment needs. The binary that has
// the engine turns it into agent-wrapper's exec (a Mac's
// MacSessionsContainer: ContainerEngine.startWrapper); nothing here knows
// agent_protocol's or the engine's types.

public struct ContainerAgent: Equatable, Sendable {
    /// The agent's id (a UUID): the wrapper's AGENT_ID, its exec's id and
    /// its log's name. A new one for each of the session's agents.
    public var agent: String
    /// The session it carries on (its token's `sub`).
    public var session: String
    public var title: String
    /// claude (nil) or another harness the wrapper knows (echo, a test's).
    public var harness: String?
    public var model: String?
    public var effort: String?
    /// Where it works, at the same path in the container as here.
    public var workingDirectory: String
    /// The harness's own conversation to resume.
    public var resumeSessionID: String
    /// Whether it acts without asking (Job.skip_permissions).
    public var skipPermissions: Bool
    /// The repositories it clones, under `sourcesDirectory`, before it
    /// resumes.
    public var sources: [Source]
    public var sourcesDirectory: String?
    /// The agent's token (a JWT for `visor.runner-agent`): AGENT_TOKEN alone.
    public var token: String
    /// More for its harness's environment (CLAUDE_CONFIG_DIR).
    public var environment: [String: String]

    public init(agent: String, session: String, title: String, harness: String? = nil, model: String? = nil, effort: String? = nil,
                workingDirectory: String, resumeSessionID: String, skipPermissions: Bool, sources: [Source] = [],
                sourcesDirectory: String? = nil, token: String, environment: [String: String] = [:]) {
        self.agent = agent
        self.session = session
        self.title = title
        self.harness = harness
        self.model = model
        self.effort = effort
        self.workingDirectory = workingDirectory
        self.resumeSessionID = resumeSessionID
        self.skipPermissions = skipPermissions
        self.sources = sources
        self.sourcesDirectory = sourcesDirectory
        self.token = token
        self.environment = environment
    }
}

extension ContainerAgent {
    /// A repository it works in: its clone URL, its branch, and its
    /// folder's name.
    public struct Source: Equatable, Sendable {
        public var repository: String
        public var ref: String
        public var name: String

        public init(repository: String, ref: String, name: String) {
            self.repository = repository
            self.ref = ref
            self.name = name
        }
    }
}
