import VisorProtocol
import VisorServices

/// The providers this build knows. The wire protocol's server, reached
/// over HTTP or the computer's SSH, is the one shipped; a fork registers
/// its own at launch, before the store is made.
/// The first is the default: what a record of an unknown kind, or the add
/// sheet with nothing chosen, gets.
@MainActor
public enum AgentServerProviders {
    private static var registry: [any AgentServerProvider] = [VisorAgentServerProvider()]

    public static var all: [any AgentServerProvider] { registry }

    public static func register(_ provider: any AgentServerProvider) {
        registry.removeAll { $0.id == provider.id }
        registry.append(provider)
    }

    public static func provider(for id: String) -> (any AgentServerProvider)? {
        let id = VisorAgentServerProvider.formerNames.contains(id) ? VisorAgentServerProvider.name : id
        return registry.first { $0.id == id }
    }

    /// The server for a record; an unknown provider gets the first.
    static func server(for record: AgentServerRecord) -> any AgentServer {
        (provider(for: record.provider) ?? registry[0]).makeServer(for: record)
    }
}
