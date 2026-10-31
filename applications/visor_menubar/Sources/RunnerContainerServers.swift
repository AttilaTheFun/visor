import Foundation
import Observation
import ServiceManagement
import VisorRunner
import VisorServer

/// The Runner's container servers (docs/co-tenancy.md) as the menu bar app
/// shows and changes them. The app writes what should be (each server's
/// folder, `runner.json`, the Runner's secrets) and the Runner's agent, a
/// LaunchAgent in the app's bundle registered here, makes it so: it makes
/// and keeps the containers, fronts their servers, and is their MCP proxy,
/// whether or not the app runs. The rows are what the agent last found.
@MainActor
@Observable
final class RunnerContainerServers {
    struct Row: Identifiable {
        var spec: ContainerServerSpec
        var state: ContainerServerState?
        var id: String { spec.id }
        var stopped: Bool { spec.stopped }
    }

    private(set) var rows: [Row] = []
    /// What the last change said, if it went wrong.
    var message: String?
    /// Where the Runner's agent stands, when it isn't running as it should
    /// (to be allowed in System Settings, say).
    private(set) var agentProblem: String?
    /// A change waiting for the agent, by server.
    var busy: Set<String> { Set(rows.filter { $0.state?.state == "starting" || $0.state == nil }.map(\.id)) }

    private let server: VisorServer
    private let data: URL
    private let folders: ContainerServerFolders
    private let secrets: FileRunnerSecrets
    /// What was last written for the agent: written again when it changes.
    private var written: (config: RunnerConfig, mcpSecrets: [String: String])?

    init(server: VisorServer) {
        self.server = server
        data = ServerPlatform.current.host.dataDirectory
        folders = ContainerServerFolders(folders: data.appendingPathComponent("container-servers", isDirectory: true))
        secrets = FileRunnerSecrets(file: data.appendingPathComponent("runner-secrets.json"))
    }

    /// The Runner's agent registered (once; macOS keeps it), and the rows and
    /// what the agent is given read and written again every few seconds.
    func start() {
        registerAgent()
        Task {
            while true {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The agent's plist in this bundle (Contents/Library/LaunchAgents),
    /// named after the app's bundle id.
    private var agent: SMAppService {
        SMAppService.agent(plistName: (Bundle.main.bundleIdentifier ?? "VisorServer") + ".runner-agent.plist")
    }

    private func registerAgent() {
        let agent = agent
        if agent.status != .enabled {
            do { try agent.register() } catch { ServerPlatform.current.log("the Runner's agent: \(error)") }
        }
        agentProblem = Self.problem(agent.status)
    }

    static func problem(_ status: SMAppService.Status) -> String? {
        switch status {
        case .enabled: return nil
        case .requiresApproval: return "Container servers need Visor's background agent: allow it in System Settings › General › Login Items."
        case .notRegistered: return "Visor's background agent isn't registered."
        case .notFound: return "Visor's background agent isn't in this app's bundle."
        @unknown default: return "Visor's background agent isn't running."
        }
    }

    /// The rows as the folders have them now; the Mac server's MCP servers
    /// and their secret headers written for the agent where they changed.
    func reload() {
        rows = folders.servers().map { Row(spec: $0, state: folders.state($0.id)) }
        agentProblem = Self.problem(agent.status)
        let config = RunnerConfig(endpoints: Self.endpoints(of: server))
        var mcpSecrets: [String: String] = [:]
        for endpoint in config.endpoints {
            for header in endpoint.secretHeaders {
                mcpSecrets["mcp \(endpoint.name) \(header)"] = ServerPlatform.current.secrets.get(MCPEndpoint.secretKey(endpoint: endpoint.name, header: header))
            }
        }
        guard written?.config != config || written?.mcpSecrets != mcpSecrets else { return }
        do {
            try config.write(data)
            let gone = Set(written?.mcpSecrets.keys.map { $0 } ?? []).subtracting(mcpSecrets.keys)
            for name in gone { secrets.set(name, nil) }
            for (name, value) in mcpSecrets { secrets.set(name, value) }
            written = (config, mcpSecrets)
        } catch {
            message = "The Runner's settings couldn't be written: \(error)"
        }
    }

    /// The Mac server's MCP servers, as the Runner's proxy passes calls on to
    /// them: their headers that aren't secret, and the names of those that are.
    static func endpoints(of server: VisorServer) -> [MCPProxy.Endpoint] {
        server.settings.mcpEndpoints.map { endpoint in
            MCPProxy.Endpoint(name: endpoint.name, url: endpoint.url,
                              headers: Dictionary(endpoint.headers.filter { !$0.secret }.map { ($0.name, $0.value) }) { $1 },
                              secretHeaders: endpoint.headers.filter(\.secret).map(\.name))
        }
    }

    // MARK: Sign-ins

    var claudeToken: String { secrets.value(ContainerServer.SignIns.claudeKey) ?? "" }
    var openrouterKey: String { secrets.value(ContainerServer.SignIns.openrouterKey) ?? "" }

    /// The token and key kept (empty: none): the agent gives them to every
    /// container server.
    func setSignIns(claudeToken: String, openrouterKey: String) {
        secrets.set(ContainerServer.SignIns.claudeKey, claudeToken.trimmingCharacters(in: .whitespacesAndNewlines))
        secrets.set(ContainerServer.SignIns.openrouterKey, openrouterKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Changes, which the agent makes so

    /// The next free port from 7440, by the servers there are.
    var nextPort: Int {
        let taken = Set(rows.map(\.spec.listen.port))
        var port = 7440
        while taken.contains(port) { port += 1 }
        return port
    }

    /// A new container server: `folder` seen in it at its own path.
    func make(name: String, image: String, port: Int, lan: Bool, vpn: Bool, folder: String) {
        var spec = ContainerServerSpec(id: UUID().uuidString.lowercased(), name: name, image: image)
        spec.listen = .init(port: port, lan: lan, vpn: vpn)
        if !folder.isEmpty { spec.mounts = [.init(source: folder)] }
        change(folders.want(spec))
    }

    func start(_ id: String) { setStopped(id, false) }

    func stop(_ id: String) { setStopped(id, true) }

    private func setStopped(_ id: String, _ stopped: Bool) {
        guard var spec = rows.first(where: { $0.id == id })?.spec else { return }
        spec.stopped = stopped
        change(folders.want(spec))
    }

    func upgrade(_ id: String) { change(folders.wantUpgrade(id)) }

    func remove(_ id: String) { change(folders.wantRemoved(id)) }

    private func change(_ problem: String?) {
        message = problem
        reload()
    }
}
