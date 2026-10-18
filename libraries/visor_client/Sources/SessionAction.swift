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
}
