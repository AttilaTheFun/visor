// Visor's agent-proxy on the Mac (docs/agent-proxy.md): this app's own
// executable, so it reads the server's keychain items (MacPlaces'
// server service) as the app does.
//
// - `Visor --agent-proxy`: the proxy itself, the launchd job the server
//   keeps (AgentProxyJob), never the app's UI.
// - `Visor agent-proxy secret-set <name>` (and `secret-remove`): one of its
//   secrets kept, piped in on standard input.
// - At the server's start: the job settled to settings.json's `agentProxy`
//   (none: none, the job removed if there was one).

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
