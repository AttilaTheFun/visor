import VisorProtocol

/// Where a job for a runner goes: the dispatcher of agent_protocol that
/// runners pull from (VisorDriver's). `POST /api/jobs` queues one.
@MainActor
package protocol AgentJobQueue: AnyObject {
    /// A job queued to start an agent (`agent`, `title`, `cwd`, `model`;
    /// its first prompt `text`): its agent's id, or why not.
    func queueStart(_ request: Envelope) -> Result<String, AgentJobRefusal>
    /// A job carrying on a session moved here's conversation on a runner
    /// (Move to a runner…): queued under the session's own id.
    func queueResume(_ move: AgentJobMove) -> Result<String, AgentJobRefusal>
    /// The session ended: any job carrying it on, waiting or claimed, goes.
    func forget(session: String)
    /// The session's agent stopped (Stop Agent, or before Restart Agent):
    /// its job, waiting or claimed, goes (its runner's next renewal is
    /// refused, so the runner ends it), but the session stays moved: its
    /// agents are still its own, and a resume job carries it on again.
    func stopJobs(of session: String)
    /// The moves sessions.json keeps for driven sessions, at the driver's
    /// start: each one the queue doesn't know is known again (its agent is
    /// its session's), and, for those in `expected`, a claim is held for its
    /// runner to renew, or its job is queued again once that claim lapses.
    /// jobs.json may be missing, older or behind (14 Nov: a server from
    /// before jobs.json, and every moved session dropped).
    func adopt(_ moves: [AgentJobMove], expected: Set<String>)
    /// What the queue keeps of the session's latest move, if anything: for
    /// a driven session whose record has none (one moved by an older build).
    func kept(session: String) -> AgentJobMove?
}

/// A session moved to a runner, as its resume job carries it; kept on the
/// session's record (sessions.json) while it is driven, so a restart knows
/// which agent carries it on even without the dispatcher's jobs.json.
package struct AgentJobMove: Codable, Equatable, Sendable {
    /// The agent its job is for (a UUID, as runners hold an agent's id to
    /// be): "" for the queue to make one.
    package var agent: String = ""
    /// The session's id, which its agent keeps on the runner.
    package var session: String
    package var title: String
    package var model: String
    package var effort: String
    /// The harness's own session to resume (Claude's conversation id).
    package var resume: String
    /// Where the session worked here: where its conversation is found.
    package var cwd: String
    /// The repositories it worked in, cloned on the runner.
    package var sources: [AgentJobSource]
    /// The kind of runner that takes it ("container", "native").
    package var runsOn: String
    /// Where its agent works on the runner, once its wrapper has said ("":
    /// where the runner puts a new job). A resume job for a later agent of
    /// the session works there too, so it finds the conversation as the
    /// runner's agent left it, and the repositories cloned.
    package var workingDirectory: String = ""
    /// The harness's own session on the runner, once its agent has started
    /// (agent_protocol's Started): what a later agent resumes. "": `resume`.
    package var conversation: String = ""
    /// Whether its agent acts without asking (the session's own setting,
    /// as it was when the job was queued): the job's skip_permissions.
    /// False, it asks, and its prompts come here (DrivenProcess).
    package var skipPermissions: Bool = false

    /// What a later agent of the session resumes: the runner's own
    /// conversation once known, else the one moved.
    package var resumeOnRunner: String { conversation.isEmpty ? resume : conversation }

    package init(agent: String = "", session: String, title: String, model: String = "", effort: String = "", resume: String, cwd: String,
                 sources: [AgentJobSource] = [], runsOn: String, workingDirectory: String = "", conversation: String = "",
                 skipPermissions: Bool = false) {
        self.agent = agent
        self.session = session
        self.title = title
        self.model = model
        self.effort = effort
        self.resume = resume
        self.cwd = cwd
        self.sources = sources
        self.runsOn = runsOn
        self.workingDirectory = workingDirectory
        self.conversation = conversation
        self.skipPermissions = skipPermissions
    }

    /// What sessions.json kept: the session, its conversation and folder
    /// here, and its runner's kind; the rest as far as it was known.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        session = try c.decode(String.self, forKey: .session)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        resume = try c.decode(String.self, forKey: .resume)
        cwd = try c.decode(String.self, forKey: .cwd)
        sources = try c.decodeIfPresent([AgentJobSource].self, forKey: .sources) ?? []
        runsOn = try c.decodeIfPresent(String.self, forKey: .runsOn) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? false
    }
}

/// A repository a moved session works in: its clone URL, its branch, and
/// its folder's name.
package struct AgentJobSource: Codable, Equatable, Sendable {
    package var repository: String
    package var ref: String
    package var name: String

    package init(repository: String, ref: String, name: String) {
        self.repository = repository
        self.ref = ref
        self.name = name
    }
}

/// Why a job wasn't queued.
package struct AgentJobRefusal: Error, Equatable {
    package let reason: String

    package init(_ reason: String) {
        self.reason = reason
    }
}
