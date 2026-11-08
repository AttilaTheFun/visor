/// A message between two sessions, as each end's mailbox keeps it
/// (docs/agent-mail.md): in the recipient's inbox once delivered, and in
/// the sender's outbox from the moment it was sent. Its id is the same in
/// both, and in the relay when the two sessions are on different servers.
/// A client reads a session's boxes with `GET /sessions/<id>/mail`.
public struct MailMessage: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Sent, not yet in the other inbox: waiting for a Visor client to
        /// carry it to the other server.
        case waiting
        /// In the recipient's inbox, not yet read.
        case delivered
        /// Read by the recipient (read_inbox).
        case read
        /// Not taken there (no such session).
        case failed
        /// Not carried to the other server before it expired.
        case expired
    }

    public var id: String
    public var from: RelayEndpoint
    public var to: RelayEndpoint
    public var text: String
    /// When it was sent, in seconds since 1970.
    public var sent: Double
    public var state: State
    /// When its state last changed, in seconds since 1970.
    public var changed: Double
    /// What went wrong, for a failed message.
    public var problem: String?

    public var unread: Bool { state == .delivered }

    public init(id: String, from: RelayEndpoint, to: RelayEndpoint, text: String, sent: Double, state: State, changed: Double,
                problem: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.sent = sent
        self.state = state
        self.changed = changed
        self.problem = problem
    }
}
