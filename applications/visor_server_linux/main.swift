// visor-server on Linux: the command-line server, given Linux's system.
// Also the agents' host, when run by that name (visor-agent-host, a link
// to this program): Visor's Linux programs are one program
// (tools/linux_programs.sh), so the Swift runtime and Foundation, linked
// in, are carried once.

import Foundation
import VisorAgentHost
import VisorMCPBridge
import VisorServerCLI
import VisorServerLinux

if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "visor-agent-host" {
    if CommandLine.arguments.dropFirst().first == "mcp" { exit(await MCPMain.run(ProcessInfo.processInfo.environment)) }
    exit(await AgentHost.main(CommandLine.arguments))
}
let status = await ServerCommand(system: LinuxSystem()).main()
exit(status)
