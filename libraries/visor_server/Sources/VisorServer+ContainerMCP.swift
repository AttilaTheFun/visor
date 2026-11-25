// The Sessions container's agents and agent-proxy's MCP pass-through
// (docs/containers.md, "MCP in the container"; 0.72.1): Nimbus's MCP (Logan,
// 25 Nov 2026: "agents can talk to the visor and nimbus mcps"; gh there is
// the gh CLI through the GitHub gate, oss is retired) reaches a container's
// agent at `http://mcp.agent.internal/mcp/nimbus`, the relay's dial-in to the
// pass-through, and each call shows the agent's own token, never the
// sessions' token (`mcp/token`), which never goes into the container. Its
// harness asks its wrapper's stream for that token (DrivenMCP: an hour's,
// for MCP alone, as the container runner mints it), and agent-proxy, in this
// same process, asks here whose it is.

import Foundation

extension VisorServer {
    /// The session a call to agent-proxy's MCP pass-through acts as, when
    /// `token` is the own token of an agent running in the Sessions container
    /// now (ContainerRunner.passThroughSession); nil for any other.
    public func passThroughSession(for token: String) -> String? {
        containerRunner.passThroughSession(for: token)
    }

    /// Each server agent-proxy's MCP pass-through serves, by its name, at
    /// its URL in the container: what the Sessions container's Claude is
    /// told of keeps Nimbus's alone (ContainerClaudeMCP.served). None without
    /// agent-proxy, or without the pass-through.
    public nonisolated static func containerMCPServers(_ settings: AgentProxySettings?) -> [String: String] {
        var servers: [String: String] = [:]
        for name in settings?.passThroughServers ?? [] { servers[name] = AgentProxySettings.containerURL(of: name) }
        return servers
    }

    /// The container's Claude folder (CLAUDE_CONFIG_DIR), on the Sessions
    /// volume at `sessions`.
    public nonisolated static func containerClaudeFolder(sessions: String) -> String {
        containerClaudeEnvironment(sessions: sessions)["CLAUDE_CONFIG_DIR"] ?? sessions + "/.claude"
    }
}
