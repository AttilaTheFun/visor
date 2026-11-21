// The Sessions container, as the server serves it (docs/containers.md):
// `GET /api/container`, its state, resources, image and errors, and
// `POST /api/container/start` and `/stop`, each an admin's (as every REST
// route is); and turning it on giving agent-proxy a relay port, its way out,
// where none is set. Without an engine (Linux, the app's own server, a
// test), it's off, and says why.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What a server without the engine says of it.
    static let noContainerEngine = "The Sessions container runs in Visor's background server on a Mac with macOS 26 or later; "
        + "this server has none."

    /// `/api/container…`, answered once the engine has.
    func routeContainer(_ request: HTTPRequest, parts: [String], respond: @escaping (HTTPResponse) -> Void) {
        let action = parts.count == 2 ? parts[1] : nil
        switch (request.method, parts.count, action) {
        case ("GET", 1, nil), ("POST", 2, "start"), ("POST", 2, "stop"): break
        default: return respond(HTTPResponse(404, "{\"error\":\"not found\"}"))
        }
        guard let engine = sessionsContainer else {
            let status = ContainerStatus(state: .off, enabled: settings.container?.enabled ?? false, relayPort: settings.agentProxy?.relayPort,
                                         errors: [Self.noContainerEngine])
            return respond(.json(status.json.encoded()))
        }
        Task {
            let status = switch action {
            case "start": await engine.start()
            case "stop": await engine.stop()
            default: await engine.status()
            }
            respond(.json(status.json.encoded()))
        }
    }

    /// The engine told of the settings, after agent-proxy is given a relay
    /// port if the container is on and it has none.
    func containerSettingsChanged() {
        guard let engine = sessionsContainer else { return }
        if settings.container?.enabled == true, settings.agentProxy?.relayPort == nil {
            let mcp = settings.agentProxy?.mcp?.port
            if let port = RelayPortChoice.choose(alsoAvoided: mcp.map { [$0] } ?? [], isFree: { engine.loopbackPortIsFree($0) }) {
                var proxy = settings.agentProxy ?? AgentProxySettings()
                proxy.relayPort = port
                Self.log("the Sessions container is on: agent-proxy's relay port is \(port), its way out")
                settings.agentProxy = proxy
                settings.keep(at: Self.settingsURL)
                engine.settingsChanged(settings)
                return
            }
            Self.log("the Sessions container is on, but no loopback port is free for agent-proxy's relay: it has no egress")
        }
        engine.settingsChanged(settings)
    }
}
