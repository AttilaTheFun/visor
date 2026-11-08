import VisorProtocol

/// A message between two sessions, as each end's mailbox keeps it
/// (docs/agent-mail.md): in the recipient's inbox once delivered, and in
/// the sender's outbox from the moment it was sent. Its id is the same in
/// both, and in the relay when the two sessions are on different servers.
struct MailMessage: Codable, Equatable {
    enum State: String, Codable {
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

    var id: String
    var from: RelayEndpoint
    var to: RelayEndpoint
    var text: String
    /// When it was sent, in seconds since 1970.
    var sent: Double
    var state: State
    /// When its state last changed, in seconds since 1970.
    var changed: Double
    /// What went wrong, for a failed message.
    var problem: String?

    var unread: Bool { state == .delivered }
}
