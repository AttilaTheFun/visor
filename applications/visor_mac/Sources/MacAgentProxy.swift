// Visor's agent-proxy on the Mac (docs/agent-proxy.md): this app's own
// executable, so it reads the server's keychain items (MacPlaces'
// server service) as the app does.
//
// - `Visor --agent-proxy`: the proxy itself, the launchd job the server
//   keeps (AgentProxyJob), never the app's UI.
// - `Visor agent-proxy secret-set <name>` (and `secret-remove`): one of its
//   secrets kept, piped in on standard input.
// - At the start of the server in the app: the job settled to
//   settings.json's `agentProxy` (none: none, the job removed if there was
//   one).
// - In the server agent (`Visor --server`): folded in, as on Linux. The job
//   is stopped and removed first, then the proxy started inside the server
//   when `agentProxy` is set.

import Foundation
import VisorAgentProxyHost
import VisorServer
import VisorServerApple

@MainActor
enum MacAgentProxy {
    /// The server's data folder (ServerPlatform.apple's) and the egress
    /// log beside the app's other logs.
    static var places: AgentProxyHost.Places {
        AgentProxyHost.Places(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                  .appendingPathComponent("Visor"),
                              egressLog: AgentProxyJob.egressLogPath())
    }

    /// Runs the proxy or its command when `arguments` ask for one, and
    /// ends the process; returns otherwise, for the app to start.
    static func handle(_ arguments: [String]) {
        let given = Array(arguments.dropFirst())
        let secrets = KeychainSecrets(service: MacPlaces.serverService)
        if given.first == AgentProxyJob.argument {
            AgentProxyHost.run(AgentProxyHost.Launch(places: places, secrets: secrets, version: VisorMacApp.bundleVersion,
                                                     logFile: AgentProxyJob.logPath()))
        }
        if given.first == "agent-proxy" {
            exit(AgentProxyCommand.main(Array(given.dropFirst()), secrets: secrets))
        }
    }

    /// What runs inside the server agent, held for its life.
    private static var folded: AgentProxyHost.Running?

    /// In the server agent: the job gone (its ports are the proxy's here),
    /// then the proxy started in this process, with the server's secrets,
    /// when `agentProxy` is set. A change takes a restart, as on Linux.
    static func foldIn(_ server: VisorServer) async {
        let log: @Sendable (String) -> Void = { ServerPlatform.current.log("agent-proxy: \($0)") }
        await AgentProxyJob.settle(bundleID: MacPlaces.own, version: VisorMacApp.bundleVersion, places: places, folded: true,
                                   log: { ServerPlatform.current.log($0) })
        guard let settings = server.settings.agentProxy else { return }
        folded = AgentProxyHost.start(settings, places: places, secrets: ServerPlatform.current.secrets, version: VisorMacApp.bundleVersion,
                                      log: log)
    }

    /// The launchd job made to match settings.json and this app, off the
    /// main thread.
    static func settle() {
        let bundleID = MacPlaces.own
        let version = VisorMacApp.bundleVersion
        let places = places
        Task.detached {
            await AgentProxyJob.settle(bundleID: bundleID, version: version, places: places, log: { ServerPlatform.current.log($0) })
        }
    }
}
