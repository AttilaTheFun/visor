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
// The GitHub proxy, for every server's agents, where a port is set: its
// authority's certificate kept beside runner.json, for the agents' systems
// to trust.
let github: GitHubProxy? = config.githubProxyPort.flatMap { port in
    do {
        let ca = try RunnerCA.kept(in: secrets)
        try ca.pem.write(to: data.appendingPathComponent("github-proxy-ca.pem"), atomically: true, encoding: .utf8)
    } catch {
        log("the GitHub proxy's authority couldn't be made: \(error)")
        return nil
    }
    let admits: @Sendable (String) -> Bool = { ProxyTokens.admits($0, servers: RunnerConfig.read(data)?.servers ?? [], in: secrets) }
    let made: GitHubProxy?
    if let app = config.githubAppID, let installation = config.githubInstallation, let ca = try? RunnerCA.kept(in: secrets) {
        made = GitHubProxy(port: port, admits: admits, ca: ca, appID: app, installation: installation,
                           key: { secrets.value(RunnerCommand.githubAppKeySecret) }, log: log)
    } else {
        made = GitHubProxy(port: port, admits: admits, log: log)
    }
    guard let started = made else {
        log("port \(port) can't be had for the GitHub proxy")
        return nil
    }
    started.start()
    log("the GitHub proxy listens on port \(port)")
    return started
}
// Where clients sign in (docs/runner-accounts.md), where a port is set: the
// user and the servers as runner.json has them at each request.
let signIn: RunnerAPIServer? = config.apiPort.flatMap { port in
    let api = RunnerAPI(auths: [RunnerPasswordAuth(user: { RunnerConfig.read(data)?.user }, secrets: secrets)],
                        sessions: RunnerSessions(secrets: secrets),
                        servers: { RunnerServerInfo.listed(in: RunnerConfig.read(data) ?? RunnerConfig()) })
    do {
        let reach: @Sendable (String) -> RunnerAPIServer.Reach? = { RunnerCommand.reach($0, folder: data, secrets: secrets) }
        let made: RunnerAPIServer?
        let over: String
        if let file = config.apiCertificateFile, let keyFile = config.apiKeyFile {
            // The tailnet's (or another a client trusts as any website's).
            made = try RunnerAPIServer(port: UInt16(port), api: api, chain: try String(contentsOfFile: file, encoding: .utf8),
                                       key: try String(contentsOfFile: keyFile, encoding: .utf8), reach: reach)
            over = file
        } else {
            let identity = try RunnerIdentity.kept(in: secrets, names: RunnerIdentity.names(given: config.apiNames))
            made = try RunnerAPIServer(port: UInt16(port), api: api, identity: identity, reach: reach)
            over = "this Runner's own certificate, SHA-256 \((try? identity.fingerprint) ?? "?")"
        }
        guard let started = made else {
            log("port \(port) can't be had for the sign-in")
            return nil
        }
        started.start()
        log("clients sign in at port \(port), over TLS with \(over)")
        return started
    } catch {
        log("the sign-in's certificate couldn't be made: \(error)")
        return nil
    }
}
// Their servers, started again when they stop answering (those with a
// command for it).
let watches = config.fronts.compactMap { ServerWatch(front: $0, log: log) }
for watch in watches { watch.start() }

// Ended by a signal (TERM, an update): heard on the main queue, which
// dispatchMain runs. (A handler on another queue would be the main actor's
// all the same, made here, and trap when called.)
let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        proxy.stop()
        for front in fronts { front.stop() }
        for watch in watches { watch.stop() }
        github?.stop()
        signIn?.stop()
        exit(0)
    }
    source.resume()
    return source
}
withExtendedLifetime(sources) { dispatchMain() }
