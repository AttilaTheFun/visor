/// Where a session's turn came from: the input that started it, as the
/// server, which hands the agent every input itself, tagged it
/// (`SessionInfo.turnOrigin`). A turn of mail (another session's message,
/// or the notice that messages wait in the inbox) tells the person
/// nothing when it ends, and its words are never the session's preview.
public enum TurnOrigin: String, Codable, Hashable, Sendable {
    /// What a client sent: the person's own words.
    case user
    /// Another session's message, handed over as a turn (headed with its
    /// sender, or `@@from`), or the notice that messages wait unread.
    case mail
    /// The server's own nudge (a turn carried on after a restart), or a
    /// turn the agent began itself (a goal's or a loop's next step).
    case system

    static let noticeStart = "[Visor: you have "
    static let noticeEnd = " in your inbox; read them with read_inbox]"
    static let messageStart = "[Message from the Visor session “"

    /// Whether a turn's words are mail, known by the forms the server
    /// hands mail over in: the inbox's notice, a message headed with its
    /// sender, or one beginning `@@from` (AgentMessageMarkers). What tells
    /// a transcript's mail rows apart, which carry no origin of their own.
    public static func isMail(_ text: String) -> Bool {
        if text.hasPrefix(noticeStart), text.hasSuffix(noticeEnd) { return true }
        if text.hasPrefix(messageStart) { return true }
        return AgentMessageMarkers.inbound(text) != nil
    }

    /// Whether an agent's reply is a message to another session
    /// (`@@to`, AgentMessageMarkers): mail too, never the preview.
    public static func isMailReply(_ text: String) -> Bool {
        AgentMessageMarkers.outbound(text) != nil
    }
}
