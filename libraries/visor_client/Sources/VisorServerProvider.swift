import VisorProtocol
import VisorServices

/// Servers speaking the wire protocol, wherever they are reached — a Mac
/// behind Tailscale, or any URL a proxy or a tunnel gives: the provider
/// shipped, and the default. Records from before it had a name of its own
/// say "tailscale", and are its.
public struct VisorServerProvider: AgentServerProvider {
    public static let name = "visor"
    /// What records called it before 0.21.
    public static let formerName = "tailscale"
    public let id = VisorServerProvider.name
    public let title = "Visor Server"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { WireAgentServer(record: record) }
}
