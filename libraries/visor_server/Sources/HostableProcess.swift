/// An adapter whose agent can run under a host (HostedChild), or in a
/// container on an oss server (OSSChild): written down with its session,
/// and picked up again by the next launch of the server rather than ended
/// with this one (VisorServer+Hosts.swift).
@MainActor
protocol HostableProcess: AgentProcess {
    /// The running agent's host, when it has one.
    var hostedChild: HostedChild? { get }
    /// The running agent in its container, when it runs in one.
    var containerChild: OSSChild? { get }
    /// Where its agent runs, when that is a container rather than this
    /// computer.
    var container: ContainerPlacement? { get set }
    /// What the adapter knows of the running agent that the next launch
    /// needs to drive it (Codex's turn in flight).
    var carried: [String: String] { get }
    /// Takes over an agent an earlier launch left running.
    func adopt(_ child: any AgentChild, carried: [String: String])
}
