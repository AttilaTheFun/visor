/// What one agent asks of a session on another server, carried by a client
/// connected to both: a message to send it, or a request to read its latest
/// rows; or (`receipt`, since 0.47) word from the server a message went to
/// that its recipient read it, `text` the message's id, for the sender's
/// outbox. A client or server from before 0.47 doesn't know a receipt: a
/// client leaves it uncarried, and a server sends none to a server reported
/// as older. Its id is the same however many clients carry it, so the server it
/// goes to takes it once; it is dropped as undeliverable once `expires`
/// (seconds since 1970) has passed.
public struct RelayMessage: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case send, read, receipt
    }

    public var id: String
    public var kind: Kind
    public var from: RelayEndpoint
    public var to: RelayEndpoint
    public var text: String
    /// For a read: how many rows.
    public var rows: Int
    public var created: Double
    public var expires: Double
    /// A message an agent wrote as words (AgentMessageMarkers): delivered as
    /// a turn beginning `@@from`, never into an inbox. A server from before
    /// it doesn't know it, and delivers it as a message from the inbox's
    /// tools.
    public var marked: Bool?

    public init(id: String, kind: Kind, from: RelayEndpoint, to: RelayEndpoint, text: String = "", rows: Int = 10,
                created: Double, expires: Double, marked: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.from = from
        self.to = to
        self.text = text
        self.rows = rows
        self.created = created
        self.expires = expires
        self.marked = marked
    }
}
