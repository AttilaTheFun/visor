import VisorProtocol
import VisorServices

/// What a server says over its live channel.
public enum AgentServerEvent: Sendable {
    /// The channel is open and signed in: the server's name, its sessions
    /// and its harnesses' catalogs.
    case welcome(name: String, sessions: [SessionInfo], catalogs: [AgentCatalog])
    /// A new list of the server's sessions.
    case sessions([SessionInfo])
    /// The harnesses' catalogs changed (a tool installed, models refreshed).
    case catalogs([AgentCatalog])
    /// An agent's account changed: its plan, or how near its limits it is.
    case account(AgentAccount, of: AgentKind)
    /// Something about one session, as the protocol says it: working or
    /// not, its ephemeral state, a new row, a notice.
    case session(Envelope)
    /// The server refused the sign-in: the credentials are wrong. The
    /// connection asks for new ones and does not retry.
    case refused(String)
    /// The server answered the sign-in with some other error.
    case failed(String)
    /// The channel closed, with the reason.
    case closed(String)
}
