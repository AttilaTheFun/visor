import Foundation
import VisorRunner

// visor-runner-agent [--data <folder>] [command]: Visor Runner's agent
// (docs/co-tenancy.md). Run with no command (or `serve`), it is every Visor
// server's MCP proxy: a server's MCP servers are set to it, each call with
// that server's token, and it passes the call on with the secret headers
// it alone keeps, so no server, and no container a server runs in, holds
// them. On the same port, a server with no APNs key of its own sends its
// pushes, unsigned, and they go on to APNs signed with the key it alone
// keeps (APNsProxy). Its other commands set what it proxies and whom
// (`help`). What it keeps is files of the data folder (by default Visor's):
// `runner.json` and `runner-secrets.json`. Ended (TERM), it stops proxying.

let given = Array(CommandLine.arguments.dropFirst())
let chosen = given.first == "--data" && given.count >= 2
let data = chosen ? URL(fileURLWithPath: given[1], isDirectory: true)
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Visor", isDirectory: true)
let arguments = Array(given.dropFirst(chosen ? 2 : 0))
let secrets = FileRunnerSecrets(file: data.appendingPathComponent("runner-secrets.json"))

guard arguments.isEmpty || arguments == ["serve"] else {
    exit(RunnerCommand(folder: data, secrets: secrets).run(arguments))
}

let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("visor-runner-agent: \($0)\n".utf8)) }
let config = RunnerConfig.read(data) ?? RunnerConfig()
// The endpoints and servers as runner.json has them now, a secret header's
// value from the Runner's secrets: a change needs no restart.
let pushes = SystemPushes.proxy(secrets: secrets)
guard let proxy = MCPProxy(port: UInt16(config.mcpPort), endpoints: { RunnerConfig.read(data)?.endpoints ?? [] },
                           admits: { ProxyTokens.admits($0, servers: RunnerConfig.read(data)?.servers ?? [], in: secrets) },
                           pushes: pushes,
                           secret: { endpoint, header in secrets.value(ProxyTokens.secretKey(endpoint: endpoint, header: header)) }) else {
    log("port \(config.mcpPort) can't be had for the MCP proxy")
    exit(1)
}
proxy.start()
log("the MCP proxy listens on port \(config.mcpPort)" + (pushes == nil ? "" : ", the push proxy too"))
// Each server's clients, at the ports set for them (as runner.json had them
// when the agent started).
let fronts = config.fronts.compactMap { front -> ClientProxy? in
    guard let started = ClientProxy(front: front) else {
        log("port \(front.port) can't be had for \(front.name)'s clients")
        return nil
    }
    started.start()
    log("\(front.name)'s clients come to port \(front.port), for \(front.host):\(front.hostPort)")
    return started
}

// Ended by a signal (TERM, an update): heard on the main queue, which
// dispatchMain runs. (A handler on another queue would be the main actor's
// all the same, made here, and trap when called.)
let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        proxy.stop()
        for front in fronts { front.stop() }
        exit(0)
    }
    source.resume()
    return source
}
withExtendedLifetime(sources) { dispatchMain() }
