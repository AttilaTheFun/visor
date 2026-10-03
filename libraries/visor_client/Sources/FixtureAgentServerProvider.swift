import VisorProtocol
import VisorServices

/// The canned server's provider, registered for screenshot tests.
public struct FixtureAgentServerProvider: AgentServerProvider {
    public static let name = "fixture"
    public let id = FixtureAgentServerProvider.name
    public let title = "Snapshot"
    public init() {}
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { FixtureAgentServer() }
}
