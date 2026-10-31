import Foundation
import Observation
import VisorRunner
import VisorServer

/// The Runner's container servers (docs/co-tenancy.md) as the menu bar app
/// keeps and shows them: made and kept through the container backend on a
/// thread of their own, picked up when the app starts, asked after every 30
/// seconds; the app's MCP proxy, which their servers' MCP servers are set
/// to; and what their agents sign in with: the Claude token and OpenRouter
/// key set here, and the Mac's Codex sign-in.
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
    /// A change under way, by server.
    private(set) var busy: Set<String> = []

    /// The MCP proxy's port, which containers reach at their gateway.
    static let mcpPort = 7439

    private let server: VisorServer
    private let servers: ContainerServers
    /// The Mac server's MCP servers, as the container servers are given
    /// them.
    private let endpoints: MCPEndpointList
    private var proxy: MCPProxy?

    init(server: VisorServer) {
        self.server = server
        let endpoints = MCPEndpointList()
        endpoints.value = Self.endpoints(of: server)
        self.endpoints = endpoints
        let secrets = ServerPlatform.current.secrets
        servers = ContainerServers(
            folders: ServerPlatform.current.host.dataDirectory.appendingPathComponent("container-servers", isDirectory: true),
            backend: PendingContainerBackend(), secrets: RunnerSecretStore(store: secrets), mcpPort: Self.mcpPort,
            endpoints: { endpoints.value },
            signIns: { Self.signIns(secrets) },
            log: { ServerPlatform.current.log("container servers: \($0)") })
    }

    /// The servers picked up and asked after on a thread of their own, the
    /// proxy listening, and the rows read again every few seconds (each
    /// server's state is written as it is found), for as long as the app
    /// runs.
    func start() {
        let servers = servers, endpoints = endpoints
        proxy = MCPProxy(port: UInt16(Self.mcpPort), endpoints: { endpoints.value }, admits: { servers.admits($0) }) { endpoint, header in
            ServerPlatform.current.secrets.get(MCPEndpoint.secretKey(endpoint: endpoint, header: header))
        }
        if let proxy { proxy.start() } else { ServerPlatform.current.log("container servers: port \(Self.mcpPort) can't be had for the MCP proxy") }
        Thread.detachNewThread { servers.run { false } }
        Task {
            while true {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The rows as the folders have them now, and the Mac server's MCP
    /// servers as they are set now.
    func reload() {
        rows = servers.servers().map { Row(spec: $0, state: servers.state($0.id)) }
        endpoints.value = Self.endpoints(of: server)
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

    nonisolated private static let claudeKey = "runner claudeToken"
    nonisolated private static let openrouterKey = "runner openrouterKey"

    var claudeToken: String { ServerPlatform.current.secrets.get(Self.claudeKey) ?? "" }
    var openrouterKey: String { ServerPlatform.current.secrets.get(Self.openrouterKey) ?? "" }

    /// What container servers' agents sign in with: the token and key set
    /// here, and the Mac's Codex sign-in.
    nonisolated static func signIns(_ secrets: any SecretStore) -> ContainerServer.SignIns {
        let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        return ContainerServer.SignIns(claudeToken: secrets.get(claudeKey).flatMap { $0.isEmpty ? nil : $0 },
                                       openrouterKey: secrets.get(openrouterKey).flatMap { $0.isEmpty ? nil : $0 },
                                       codexAuth: try? Data(contentsOf: codex))
    }

    /// The token and key kept (empty: none), and given to every container
    /// server at once.
    func setSignIns(claudeToken: String, openrouterKey: String) {
        for (key, value) in [(Self.claudeKey, claudeToken), (Self.openrouterKey, openrouterKey)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            ServerPlatform.current.secrets.set(key, trimmed.isEmpty ? nil : trimmed)
        }
        let servers = servers
        perform(nil) {
            servers.round()
            return nil
        }
    }

    // MARK: Changes

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
        let servers = servers, made = spec
        perform(made.id) { servers.make(made) }
    }

    func start(_ id: String) {
        let servers = servers
        perform(id) { servers.start(id) }
    }

    func stop(_ id: String) {
        let servers = servers
        perform(id) { servers.stop(id) }
    }

    func upgrade(_ id: String) {
        let servers = servers
        perform(id) { servers.upgrade(id) }
    }

    func remove(_ id: String) {
        let servers = servers
        perform(id) {
            servers.remove(id)
            return nil
        }
    }

    /// A change made off the main actor (`container` takes a while), then
    /// the rows read again and what went wrong said.
    private func perform(_ id: String?, _ change: @escaping @Sendable () -> String?) {
        if let id { busy.insert(id) }
        message = nil
        Task {
            let problem = await Task.detached { change() }.value
            if let id { busy.remove(id) }
            if let problem { message = problem }
            reload()
        }
    }
}
