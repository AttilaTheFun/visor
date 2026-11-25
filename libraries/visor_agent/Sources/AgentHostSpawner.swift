// What starts an agent's host (visor-agent-host) for the server: given the
// request (AgentHostSpawnRequest: the session, its folder and harness, the
// agent's command, environment and credential, and the host's socket), it
// starts the host and says whether it's still running while the server
// waits for it to listen. AgentChildren and HostedChild take one. The one
// there is is the server's own (ProcessAgentHostSpawner: the host a child
// of the server's process, as it always was): Visor's server runs native
// sessions itself (docs/sandboxed.md, Logan, 24 Nov 2026). The server then
// talks to the host at its socket.

import AgentHostWire

/// Starts agents' hosts.
@MainActor
package protocol AgentHostSpawner {
    /// Starts a host for `request`, whose program is `program` where the
    /// spawner runs it itself; the host started, or why it wasn't.
    func spawn(_ request: AgentHostSpawnRequest, program: String) throws -> any SpawnedAgentHost
}
