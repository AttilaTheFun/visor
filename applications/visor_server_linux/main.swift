// visor-server on Linux: the command-line server, given Linux's system.
// Also the agents' host, when run by that name (visor-agent-host, a link
// to this program): Visor's Linux programs are one program
// (tools/linux_programs.sh), so the Swift runtime and Foundation, linked
// in, are carried once.
//
// agent_protocol beside it, from the environment:
// - VISOR_AGENT_PROTOCOL_PORT: the driver and dispatcher on that port
//   (VISOR_AGENT_PROTOCOL_HOST, 127.0.0.1 unless given), known to wrappers
//   and runners as VISOR_AGENT_PROTOCOL_URL (http://<host>:<port> unless
//   given), and to containers as VISOR_AGENT_PROTOCOL_CONTAINER_URL when
//   set (Shireworks' agent-proxy: http://visor.agent.internal:<port>), its jobs' harness VISOR_JOB_HARNESS (claude unless given; echo
//   for a test without a model);
// - VISOR_NATIVE_RUNNER_WRAPPER: a native runner on this computer, pulling
//   from that dispatcher and running agents under that agent-wrapper.

import Foundation
import VisorAgentHost
import VisorDriver
import VisorMCPBridge
import VisorNativeRunner
import VisorServer
import VisorServerCLI
import VisorServerLinux

if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "visor-agent-host" {
    if CommandLine.arguments.dropFirst().first == "mcp" { exit(await MCPMain.run(ProcessInfo.processInfo.environment)) }
    exit(await AgentHost.main(CommandLine.arguments))
}

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
    guard let agentProtocol else { return }
    agentProtocol.serve(server)
    let url = agentProtocol.url
    if let wrapper = environment["VISOR_NATIVE_RUNNER_WRAPPER"], !wrapper.isEmpty,
       let runner = NativeRunner(dispatcher: url, wrapper: wrapper, name: ProcessInfo.processInfo.hostName,
                                 log: { VisorServer.log($0) }) {
        Task { await runner.run() }
        VisorServer.log("native runner: pulling from \(url), running agents under \(wrapper)")
    }
}).main()
exit(status)
