import Foundation

/// An MCP server agent-proxy answers itself, in its own process, at the
/// pass-through's `/mcp/<name>` (NativeMCPProxy), where no upstream of that
/// name is configured: gh_mcp's, folded into Visor (VisorAgentProxyHost's
/// GitHubMCP). A call reaches it only once it has shown the sessions'
/// token, so who it is from is what its headers say (CLIENT_ID, the
/// session's id).
public protocol InProcessMCP: Sendable {
    /// The answer to one call: its method, its headers (names as the
    /// caller wrote them, the sessions' token left out) and its body.
    func answer(method: String, headers: [String: String], body: Data) async -> InProcessMCPAnswer
}
