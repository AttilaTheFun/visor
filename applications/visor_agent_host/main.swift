import Foundation
import VisorAgentHost
import VisorMCPBridge

// `visor-agent-host mcp`: Visor's MCP server, as each agent session is given
// it (libraries/visor_mcp_bridge); `mcp-headers`, the headers a Sessions
// container agent shows agent-proxy's MCP pass-through. Otherwise an agent's
// host.
if CommandLine.arguments.dropFirst().first == "mcp" {
    exit(await MCPMain.run(ProcessInfo.processInfo.environment))
}
if CommandLine.arguments.dropFirst().first == "mcp-headers" {
    exit(MCPHeadersMain.run(ProcessInfo.processInfo.environment))
}
exit(await AgentHost.main(CommandLine.arguments))
