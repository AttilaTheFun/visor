import Foundation
import VisorAgentHost
import VisorMCPBridge

// `visor-agent-host mcp`: Visor's MCP server, as each agent session is given
// it (libraries/visor_mcp_bridge). Otherwise an agent's host.
if CommandLine.arguments.dropFirst().first == "mcp" {
    exit(await MCPMain.run(ProcessInfo.processInfo.environment))
}
exit(await AgentHost.main(CommandLine.arguments))
