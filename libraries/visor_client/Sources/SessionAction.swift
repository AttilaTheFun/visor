/// One command on a session, for `AgentServer.act`.
public enum SessionAction: Equatable, Sendable {
    /// Interrupts the turn.
    case stop
    /// Takes a message out of the queue (every queued one when nil).
    case unqueue(text: String?)
    case permissions(skip: Bool)
    case settings(model: String?, effort: String?)
    case approve(id: String, allow: Bool)
    case rename(title: String)
    case archive
    case unarchive
    /// Ends the session and its agent.
    case end
}
