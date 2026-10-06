import VisorProtocol
import VisorServices

/// Servers speaking the wire protocol over HTTP, wherever they are
/// reached — a name on a network, or any URL a proxy, a tunnel or a port
/// gives: the provider shipped first, and the default. Records from
/// before 0.22 named it "visor", and before 0.21 after the VPN that
/// reached it then; both are its.
public struct HTTPAgentServerProvider: AgentServerProvider {
    public static let name = "http"
    /// What records called it before.
    public static let formerNames = ["visor", "tailscale"]
    public let id = HTTPAgentServerProvider.name
    public let title = "Address (HTTP)"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { HTTPAgentServer(record: record) }
}
