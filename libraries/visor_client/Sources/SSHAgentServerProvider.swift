import VisorProtocol
import VisorServices

/// Servers reached over SSH (`SSHAgentServer`): offered where the host has
/// SSH (a Mac, an iPhone), as the second way in beside HTTP.
public struct SSHAgentServerProvider: AgentServerProvider {
    public static let name = "ssh"
    public let id = SSHAgentServerProvider.name
    public let title = "SSH"
    public init() {}
    public var available: Bool { VisorHost.ssh != nil }
    public func makeServer(for record: AgentServerRecord) -> any AgentServer { SSHAgentServer(record: record) }
}
