// visor-server on Linux: the command-line server, given Linux's system.
// Also the agents' host and relay-client, when run by those names
// (visor-agent-host and relay-client, links to this program): Visor's Linux
// programs are one program (tools/linux_programs.sh), so the Swift runtime,
// Foundation and its ICU data, NIO and BoringSSL, linked in, are carried
// once.
//
// agent_protocol beside it, from the environment:
// - VISOR_AGENT_PROTOCOL_PORT: the driver and dispatcher on that port
//   (VISOR_AGENT_PROTOCOL_HOST, 127.0.0.1 unless given), known to wrappers
//   and runners as VISOR_AGENT_PROTOCOL_URL (http://<host>:<port> unless
//   given), and to containers as VISOR_AGENT_PROTOCOL_CONTAINER_URL when
//   set (Shireworks' agent-proxy: http://visor.agent.internal:<port>), its jobs' harness VISOR_JOB_HARNESS (claude unless given; echo
//   for a test without a model);
// - VISOR_NATIVE_RUNNER_WRAPPER: a native runner on this computer, pulling
//   from that dispatcher and running agents under that agent-wrapper, with
//   a runner token of its own (minted at each start, in memory).
//
// And agent-proxy (docs/agent-proxy.md), inside this process, where
// settings.json has `agentProxy` (none: nothing starts): started once the
// server is made, its secrets the server's. `visor-server agent-proxy
// secret-set <name>` keeps one of them, piped in.

import Foundation
import VisorAgentHost
import VisorAgentProxyHost
import VisorDriver
import VisorMCPBridge
import VisorNativeRunner
import VisorServer
import VisorServerCLI
import VisorServerLinux
#if canImport(VisorRelayClient)
import VisorRelayClient
#endif

let programName = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
if programName == "visor-agent-host" {
    if CommandLine.arguments.dropFirst().first == "mcp" { exit(await MCPMain.run(ProcessInfo.processInfo.environment)) }
    // The Sessions container's Claude's headersHelper for agent-proxy's MCP pass-through.
    if CommandLine.arguments.dropFirst().first == "mcp-headers" { exit(MCPHeadersMain.run(ProcessInfo.processInfo.environment)) }
    exit(await AgentHost.main(CommandLine.arguments))
}
#if canImport(VisorRelayClient)
if programName == "relay-client" { exit(await RelayClientCommand.main(CommandLine.arguments)) }
#endif

let environment = ProcessInfo.processInfo.environment
let agentProtocol = environment["VISOR_AGENT_PROTOCOL_PORT"].flatMap(Int.init).flatMap { port -> VisorDriver.Listening? in
    guard port > 0 else { return nil }
    let host = environment["VISOR_AGENT_PROTOCOL_HOST"] ?? "127.0.0.1"
    return VisorDriver.Listening(host: host, port: port, url: environment["VISOR_AGENT_PROTOCOL_URL"] ?? "http://\(host):\(port)",
                                 containerURL: environment["VISOR_AGENT_PROTOCOL_CONTAINER_URL"],
                                 harness: environment["VISOR_JOB_HARNESS"] ?? "claude")
}
// The driver's port open before the sessions are read (the wrappers and
// runners of sessions moved to runners redial it), then the server served.
let status = await ServerCommand(system: LinuxSystem(), beforeServer: { agentProtocol?.listen() }, onServer: { server in
    if let settings = server.settings.agentProxy {
        let places = AgentProxyHost.Places(dataDirectory: ServerPlatform.current.host.dataDirectory)
        // Its listeners run on threads of their own, holding what they use.
        _ = AgentProxyHost.start(settings, places: places, secrets: ServerPlatform.current.secrets,
                                 version: ServerPlatform.current.host.version, log: { VisorServer.log("agent-proxy: \($0)") })
    }
    guard let agentProtocol else { return }
    agentProtocol.serve(server)
    let url = agentProtocol.url
    // Its own runner token, so it claims when runner tokens are required.
    let name = ProcessInfo.processInfo.hostName
    if let wrapper = environment["VISOR_NATIVE_RUNNER_WRAPPER"], !wrapper.isEmpty,
       let runner = NativeRunner(dispatcher: url, wrapper: wrapper, name: name, token: agentProtocol.runnerToken(for: name),
                                 log: { VisorServer.log($0) }) {
        Task { await runner.run() }
        VisorServer.log("native runner: pulling from \(url), running agents under \(wrapper)")
    }
}, agentProxy: { arguments, secrets in AgentProxyCommand.main(arguments, secrets: secrets) }).main()
exit(status)
