import VisorProtocol
import VisorServices

/// Macs running the menu bar app, reached over Tailscale: the provider
/// shipped, and the default.
public struct TailscaleAgentServerProvider: AgentServerProvider {
    public static let name = "tailscale"
    public let id = TailscaleAgentServerProvider.name
    public let title = "Tailscale"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { TailscaleAgentServer(record: record) }
}
