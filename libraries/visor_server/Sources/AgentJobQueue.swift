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
}

/// A session moved to a runner, as its resume job carries it.
package struct AgentJobMove: Equatable, Sendable {
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

    package init(session: String, title: String, model: String = "", effort: String = "", resume: String, cwd: String,
                 sources: [AgentJobSource] = [], runsOn: String) {
        self.session = session
        self.title = title
        self.model = model
        self.effort = effort
        self.resume = resume
        self.cwd = cwd
        self.sources = sources
        self.runsOn = runsOn
    }
}

/// A repository a moved session works in: its clone URL, its branch, and
/// its folder's name.
package struct AgentJobSource: Equatable, Sendable {
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
