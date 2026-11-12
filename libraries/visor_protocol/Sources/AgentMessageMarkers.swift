/// Agents' messages to one another, as plain words in their conversations
/// (Logan, 12 Nov 2026): an agent sends one by beginning a reply with
/// `@@to <session> on <computer>` and its message below; the session it
/// names takes it as a turn beginning `@@from <session> on <computer>`, the
/// sender's. Clients carry them between computers and draw them as sent and
/// received messages. The markers are read and written here alone, so they
/// can change in one place.
public enum AgentMessageMarkers {
    /// A message's address and words: the session and computer it goes to
    /// (an outbound one) or came from (an inbound one).
    public struct Addressed: Equatable, Sendable {
        public var session: String
        public var computer: String
        public var body: String

        public init(session: String, computer: String, body: String) {
            self.session = session
            self.computer = computer
            self.body = body
        }
    }

    static let outboundMarker = "@@to "
    static let inboundMarker = "@@from "
    static let separator = " on "

    /// An agent's reply that is a message to another session: its first
    /// line `@@to <session> on <computer>`, its message the lines after.
    /// Nil for any other reply, or one with no words to send.
    public static func outbound(_ text: String) -> Addressed? { parse(text, marker: outboundMarker) }

    /// A turn that is another session's message: `@@from <session> on
    /// <computer>`, then its words.
    public static func inbound(_ text: String) -> Addressed? { parse(text, marker: inboundMarker) }

    /// An outbound message's words, as an agent writes them.
    public static func outboundText(to session: String, on computer: String, body: String) -> String {
        outboundMarker + session + separator + computer + "\n\n" + body
    }

    /// The turn a message is delivered as, from `session` on `computer`.
    public static func inboundText(from session: String, on computer: String, body: String) -> String {
        inboundMarker + session + separator + computer + "\n\n" + body
    }

    /// The first line, after any blank ones, must be the marker and an
    /// address; the computer is after the last " on ", so a session's name
    /// may hold the word itself.
    private static func parse(_ text: String, marker: String) -> Addressed? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !$0.trimmingWhitespace.isEmpty }) else { return nil }
        let head = lines[first].trimmingWhitespace
        guard head.hasPrefix(marker) else { return nil }
        let address = head.dropFirst(marker.count)
        // The standard library's own search, not Foundation's: Visor on the
        // web has no NSString bridge to lean on.
        guard let split = address.ranges(of: separator).last else { return nil }
        let session = address[..<split.lowerBound].trimmingWhitespace
        let computer = address[split.upperBound...].trimmingWhitespace
        let body = lines[(first + 1)...].joined(separator: "\n").trimmingWhitespace
        guard !session.isEmpty, !computer.isEmpty, !body.isEmpty else { return nil }
        return Addressed(session: session, computer: computer, body: body)
    }
}

private extension StringProtocol {
    /// Without the spaces and line breaks around it.
    var trimmingWhitespace: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view.removeFirst() }
        while let last = view.last, last.isWhitespace { view.removeLast() }
        return String(view)
    }
}
