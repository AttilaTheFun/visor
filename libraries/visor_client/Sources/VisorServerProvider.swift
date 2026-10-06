import VisorProtocol
import VisorServices

/// Servers speaking the wire protocol, wherever they are reached — a name
/// on a network, or any URL a proxy, a tunnel or a port gives: the
/// provider shipped, and the default. Records from before 0.21 name it by
/// the VPN that reached it then, and are its.
public struct VisorServerProvider: AgentServerProvider {
    public static let name = "visor"
    /// What records called it before 0.21 (after the VPN then in use).
    public static let formerName = "tailscale"
    public let id = VisorServerProvider.name
    public let title = "Visor Server"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { WireAgentServer(record: record) }
}
