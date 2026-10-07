import VisorProtocol
import VisorServices

/// Visor servers — the wire protocol, reached as the address says: over
/// HTTP or HTTPS at a name or a URL, or through the computer's own SSH
/// (`user@host`) — the provider shipped, and the default. Records from
/// before 0.21 named it after the VPN that reached it then; a few from
/// between named the transport; all are its.
public struct VisorAgentServerProvider: AgentServerProvider {
    public static let name = "visor"
    /// What records called it before.
    public static let formerNames = ["http", "tailscale"]
    public let id = VisorAgentServerProvider.name
    public let title = "Visor Server"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { VisorAgentServer(record: record) }
}
