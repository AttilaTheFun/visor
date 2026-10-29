import VisorProtocol

/// One command on a session, for `AgentServer.act`.
public enum SessionAction: Equatable, Sendable {
    /// Interrupts the turn.
    case stop
    /// Takes a message out of the queue (every queued one when nil).
    case unqueue(text: String?)
    case permissions(skip: Bool)
    case settings(model: String?, effort: String?)
    /// Answers a tool call waiting on the user: allowed or denied, and a
    /// question's answers (by question) when the call was a question.
    case approve(id: String, allow: Bool, answers: [String: String]?)
    case rename(title: String)
    case archive
    case unarchive
    /// Ends the session's agent and starts it again on the same
    /// conversation; a turn it was working on is carried on.
    case restartAgent
    /// Ends the session's agent and keeps it ended (`AgentState.stopped`)
    /// until `startAgent`; what is sent meanwhile waits in the queue.
    case stopAgent
    case startAgent
    /// The conversation went on elsewhere (`SessionInfo.otherBranch`): keep
    /// to this branch, which the next message carries on, or continue the
    /// newest one instead.
    case keepBranch
    case continueBranch
    /// Ends the session and its agent.
    case end
    /// A fork or branch of the session (docs/sub-sessions.md), by the
    /// client's id for it: up to `at` (a row's id) for a branch, started
    /// on `prompt` when there is one, named `title` when it is given.
    case fork(id: String, origin: SessionOrigin, at: String?, prompt: String?, title: String?)
    /// A side question about the session's conversation (`/btw`), by the
    /// client's id for it.
    case side(id: String, question: String)
    /// The session's side questions go.
    case endSide
    /// The person's words for one of the session's subagents, by its id,
    /// passed on by the session's agent.
    case toSubagent(id: String, text: String)
    /// The person is done with one of the session's subagents.
    case closeSubagent(id: String)
}
