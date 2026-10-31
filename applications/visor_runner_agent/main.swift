import Foundation
import Synchronization
import VisorRunner

// visor-runner-agent [<data folder>]: the Runner's agent (docs/co-tenancy.md),
// a LaunchAgent of Visor's menu bar app, in its bundle (Contents/Helpers).
// It makes the container servers as their folders say, asks after them,
// fronts each with the Runner's reverse proxy, and is every server's MCP
// proxy, so that quitting or updating the menu bar app leaves clients and
// agents served. What it shares with the app is files of the data folder
// (by default the app's): the servers' folders, `runner.json`, the secrets.
// Ended (TERM, an update), it stops proxying and leaves the containers and
// their servers running.

let data = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Visor", isDirectory: true)
let secrets = FileRunnerSecrets(file: data.appendingPathComponent("runner-secrets.json"))
let config = RunnerConfig.read(data) ?? RunnerConfig()
let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("visor-runner-agent: \($0)\n".utf8)) }

let servers = ContainerServers(
    folders: data.appendingPathComponent("container-servers", isDirectory: true),
    backend: UnavailableContainerBackend(), secrets: secrets, mcpPort: config.mcpPort,
    endpoints: { RunnerConfig.read(data)?.endpoints ?? [] },
    signIns: { ContainerServer.SignIns.kept(in: secrets) },
    log: log)

// Every server's MCP calls: the endpoints as runner.json has them now, a
// secret header's value from the Runner's secrets.
let proxy = MCPProxy(port: UInt16(config.mcpPort), endpoints: { RunnerConfig.read(data)?.endpoints ?? [] },
                     admits: { servers.admits($0) }) { endpoint, header in secrets.value("mcp \(endpoint) \(header)") }
if let proxy { proxy.start() } else { log("port \(config.mcpPort) can't be had for the MCP proxy") }

let stopped = Mutex(false)
let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { stopped.withLock { $0 = true } }
    source.resume()
    return source
}
withExtendedLifetime(sources) { servers.run { stopped.withLock { $0 } } }
proxy?.stop()
exit(0)
