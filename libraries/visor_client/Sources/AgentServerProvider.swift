import VisorProtocol
import VisorServices

/// A kind of agent server a client can add: Visor servers, reached at any
/// address, are the one shipped; a fork registers its own (`AgentServerProviders.register`) and
/// gives its views in `VisorUI` (`AgentServerProviderUI`). The provider
/// makes the `AgentServer` for each saved record of its kind.
public protocol AgentServerProvider: Sendable {
    /// What a record names to find its provider; "visor" is the one shipped.
    var id: String { get }
    var title: String { get }
    @MainActor func makeServer(for record: AgentServerRecord) -> any AgentServer
}
