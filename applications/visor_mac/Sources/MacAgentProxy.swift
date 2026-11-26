// Visor's agent-proxy on the Mac (docs/agent-proxy.md): this app's own
// executable, so it reads the server's keychain items (MacPlaces'
// server service) as the app does.
//
// - `Visor --agent-proxy`: the proxy itself, the launchd job the server in
//   the app kept until 0.72.1 (AgentProxyJob), never the app's UI; its job
//   is removed as the server folds the proxy in.
// - `Visor agent-proxy secret-set <name>` (and `secret-remove`): one of its
//   secrets kept, piped in on standard input.
// - In the server, in the app's process (from 0.72.1, MacServer.run) or the
//   server agent's (`Visor --server`, until then): folded in, as on Linux.
//   The job is stopped and removed first, then the proxy started inside the
//   server when `agentProxy` is set, and started again when it changes
//   (`refold`: the Sessions container turned on gives it a relay port). Here,
//   beside the Sessions container, its MCP pass-through takes each container
//   agent's own token too, the server saying whose it is.

import Foundation
import VisorAgentProxyHost
import VisorServer
import VisorServerApple

@MainActor
enum MacAgentProxy {
    /// The server's data folder (MacPlaces': on the Visor volume once it's
    /// there) and the egress log beside Visor's other logs.
    static var places: AgentProxyHost.Places {
        AgentProxyHost.Places(dataDirectory: MacPlaces.data, egressLog: AgentProxyJob.egressLogPath(logs: MacPlaces.folders.logs.path))
    }

    /// Runs the proxy or its command when `arguments` ask for one, and
    /// ends the process; returns otherwise, for the app to start.
    static func handle(_ arguments: [String]) {
        let given = Array(arguments.dropFirst())
        let secrets = KeychainSecrets(service: MacPlaces.serverService)
        if given.first == AgentProxyJob.argument {
            // Where Visor's things are; nothing moved here (the server's to do).
            MacPlaces.settle(runsServer: false, client: false, log: { NSLog("Visor agent-proxy: %@", $0) })
            AgentProxyHost.run(AgentProxyHost.Launch(places: places, secrets: secrets, version: VisorMacApp.bundleVersion,
                                                     logFile: AgentProxyJob.logPath(logs: MacPlaces.folders.logs.path)))
        }
        if given.first == "agent-proxy" {
            exit(AgentProxyCommand.main(Array(given.dropFirst()), secrets: secrets))
        }
    }

    /// What runs inside the server, held for its life, and the
    /// settings it was started with (AgentProxyHost.digest); nil until
    /// it's folded in.
    private static var folded: AgentProxyHost.Running?
    private static var foldedDigest: String?
    /// Whose a container agent's token is, as the server in this process
    /// says (VisorServer.passThroughSession), once it's folded in; and
    /// whether a token may be one at all, said at once from the server's
    /// keys (VisorServer.passThroughTokenCheck) before that is waited on.
    private static var agentSession: (@Sendable (String) async -> String?)?
    private static var agentTokenCheck: (@Sendable (String) -> Bool)?

    /// In the server: the job gone (its ports are the proxy's here),
    /// then the proxy started in this process, with the server's secrets,
    /// when `agentProxy` is set. A change takes a restart, as on Linux.
    static func foldIn(_ server: VisorServer) async {
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log("agent-proxy: \($0)") }
        await AgentProxyJob.settle(bundleID: MacPlaces.own, version: VisorMacApp.bundleVersion, places: places, folded: true,
                                   logs: MacPlaces.folders.logs.path, log: { ServerPlatform.current.log($0) })
        foldedDigest = AgentProxyHost.digest(server.settings.agentProxy)
        let session: @Sendable (String) async -> String? = { token in await server.passThroughSession(for: token) }
        agentSession = session
        let check = server.passThroughTokenCheck
        agentTokenCheck = check
        guard let settings = server.settings.agentProxy else { return }
        folded = AgentProxyHost.start(settings, places: places, secrets: ServerPlatform.current.secrets, version: VisorMacApp.bundleVersion,
                                      agentSession: session, agentTokenCheck: check, log: log)
    }

    /// In the server, once folded in: started again with `settings`
    /// when they aren't what it runs with (the Sessions container turned
    /// on, giving it a relay port: docs/containers.md). Else nothing.
    static func refold(_ settings: AgentProxySettings?) {
        guard let digest = foldedDigest, digest != AgentProxyHost.digest(settings) else { return }
        foldedDigest = AgentProxyHost.digest(settings)
        folded?.stop()
        folded = nil
        guard let settings else { return }
        ServerPlatform.current.log("agent-proxy: its settings changed: started again")
        folded = AgentProxyHost.start(settings, places: places, secrets: ServerPlatform.current.secrets, version: VisorMacApp.bundleVersion,
                                      agentSession: agentSession, agentTokenCheck: agentTokenCheck,
                                      log: { ServerPlatform.current.log("agent-proxy: \($0)") })
    }
}
