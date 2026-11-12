import VisorProtocol

/// Where a job for a runner goes: the dispatcher of agent_protocol that
/// runners pull from (VisorDriver's). `POST /api/jobs` queues one.
@MainActor
package protocol AgentJobQueue: AnyObject {
    /// A job queued to start an agent (`agent`, `title`, `cwd`, `model`;
    /// its first prompt `text`): its agent's id, or why not.
    func queueStart(_ request: Envelope) -> Result<String, AgentJobRefusal>
}

/// Why a job wasn't queued.
package struct AgentJobRefusal: Error, Equatable {
    package let reason: String

    package init(_ reason: String) {
        self.reason = reason
    }
}
