/// An adapter whose agent can run under a host (HostedChild): written down
/// with its session, and picked up again by the next launch of the server
/// rather than ended with this one (VisorServer+Hosts.swift).
@MainActor
protocol HostableProcess: AgentProcess {
    /// The running agent's host, when it has one.
    var hostedChild: HostedChild? { get }
    /// What the adapter knows of the running agent that the next launch
    /// needs to drive it (Codex's turn in flight).
    var carried: [String: String] { get }
    /// Takes over an agent an earlier launch left running.
    func adopt(_ child: HostedChild, carried: [String: String])
}
