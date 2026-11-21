// gh_mcp in agent-proxy (Logan, 2026-11-21: "fold gh_mcp into Visor's
// agent-proxy at /mcp/gh, retire the LaunchAgent and binary";
// docs/agent-proxy.md): libraries/visor_gh_mcp's server, answered in
// agent-proxy's own process at the pass-through's `/mcp/gh` (an
// InProcessMCP), from ServerSettings' `agentProxy.gh`. No key of its own:
// a call has shown the sessions' token to get here, and its CLIENT_ID (the
// session's id) says which session it is.

import Foundation
import VisorAgentProxy
import VisorGHMCP

struct GitHubMCP: InProcessMCP {
    /// The pass-through's name for it, as gh_mcp's upstream had: sessions'
    /// tools stay `gh__<tool>`.
    static let name = "gh"

    let server: MCPServer

    func answer(method: String, headers: [String: String], body: Data) async -> InProcessMCPAnswer {
        let answered = await server.handle(MCPHTTPRequest(method: method, headers: headers, body: body))
        return InProcessMCPAnswer(status: answered.status, headers: answered.headers, body: answered.body)
    }
}
