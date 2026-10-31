import Foundation
import Observation
import VisorContainerHost
import VisorRunner
import VisorServer

/// The Runner's container servers as Settings shows them (docs/co-tenancy.md):
/// each one's spec, what its host last found and whether it is stopped; and
/// what the Runner gives their hosts: the Claude token and OpenRouter key
/// set here, the Mac's Codex sign-in, and the Mac server's MCP servers with
/// their secret headers.
@MainActor
@Observable
final class RunnerContainerServers {
    struct Row: Identifiable {
        var spec: ServerSpec
        var state: ServerState?
        var stopped: Bool
        var id: String { spec.id }
    }

    private(set) var rows: [Row] = []
    /// What the last change said, if it went wrong.
    var message: String?
    /// A change under way (a host's command), by server.
    private(set) var busy: Set<String> = []

    private let jobs = ContainerServerJobs.runner
    private let server: VisorServer

    init(server: VisorServer) {
        self.server = server
    }

    /// The rows read again every few seconds, for as long as the app runs:
    /// each host writes what it finds as it goes.
    func watch() {
        Task {
            while true {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The rows as the folders have them now.
    func reload() {
        let jobs = jobs
        rows = jobs.servers().map { Row(spec: $0, state: jobs.state($0.id), stopped: jobs.record($0.id).stopped) }
    }

    // MARK: Credentials

    private static let claudeKey = "runner claudeToken"
    private static let openrouterKey = "runner openrouterKey"

    var claudeToken: String { ServerPlatform.current.secrets.get(Self.claudeKey) ?? "" }
    var openrouterKey: String { ServerPlatform.current.secrets.get(Self.openrouterKey) ?? "" }

    /// The token and key kept (empty: none), and given to every container
    /// server's host.
    func setCredentials(claudeToken: String, openrouterKey: String) {
        for (key, value) in [(Self.claudeKey, claudeToken), (Self.openrouterKey, openrouterKey)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            ServerPlatform.current.secrets.set(key, trimmed.isEmpty ? nil : trimmed)
        }
        for row in rows { giveCredentials(row.id) }
    }

    /// What a host's `credentials` is given: the token and key (null when
    /// unset, so a host forgets one taken away), the Mac's Codex sign-in,
    /// and the MCP servers' secret headers.
    private func credentials() -> Data {
        var given: [String: Any] = [:]
        given["claudeToken"] = claudeToken.isEmpty ? NSNull() : claudeToken
        given["openrouterKey"] = openrouterKey.isEmpty ? NSNull() : openrouterKey
        let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if let auth = try? Data(contentsOf: codex) { given["codexAuth"] = auth.base64EncodedString() }
        var secrets: [String: String] = [:]
        for endpoint in server.settings.mcpEndpoints {
            for header in endpoint.headers where header.secret {
                if let value = server.mcpSecret(endpoint: endpoint.name, header: header.name) {
                    secrets["\(endpoint.name) \(header.name)"] = value
                }
            }
        }
        given["mcpSecrets"] = secrets
        return (try? JSONSerialization.data(withJSONObject: given)) ?? Data("{}".utf8)
    }

    private func giveCredentials(_ id: String) {
        let jobs = jobs, given = credentials()
        perform(id) {
            if case .failure(let error) = jobs.credentials(id, given) { return "\(error)" }
            return nil
        }
    }

    // MARK: Changes

    /// The next free pair of ports from 7440 (clients', then the MCP
    /// proxy's), by the servers there are.
    var nextPort: Int {
        let taken = Set(rows.flatMap { [$0.spec.listen.port, $0.spec.listen.port + 1] })
        var port = 7440
        while taken.contains(port) || taken.contains(port + 1) { port += 2 }
        return port
    }

    /// A new container server: `folder` seen in it at its own path, the Mac
    /// server's MCP servers its agents', its job loaded and its credentials
    /// given.
    func make(name: String, image: String, port: Int, lan: Bool, vpn: Bool, folder: String) {
        var spec = ServerSpec(id: UUID().uuidString.lowercased(), name: name, image: image)
        spec.listen.port = port
        spec.listen.lan = lan
        spec.listen.vpn = vpn
        if !folder.isEmpty { spec.mounts = [ServerSpec.Mount(source: folder)] }
        spec.mcp = server.settings.mcpEndpoints.map { endpoint in
            ServerSpec.Endpoint(name: endpoint.name, url: endpoint.url,
                                headers: Dictionary(endpoint.headers.filter { !$0.secret }.map { ($0.name, $0.value) }) { $1 },
                                secretHeaders: endpoint.headers.filter(\.secret).map(\.name))
        }
        let jobs = jobs, given = credentials(), made = spec
        perform(made.id) {
            do {
                return try jobs.make(made, credentials: given)
            } catch {
                return "\(error)"
            }
        }
    }

    func start(_ id: String) {
        let jobs = jobs
        perform(id) { jobs.start(id) }
    }

    func stop(_ id: String) {
        let jobs = jobs
        perform(id) { jobs.stop(id) }
    }

    func remove(_ id: String) {
        let jobs = jobs
        perform(id) { jobs.remove(id) }
    }

    /// A change made off the main actor (a host's commands take a while),
    /// then the rows read again and what went wrong said.
    private func perform(_ id: String, _ change: @escaping @Sendable () -> String?) {
        busy.insert(id)
        message = nil
        Task {
            let problem = await Task.detached { change() }.value
            busy.remove(id)
            if let problem { message = problem }
            reload()
        }
    }
}
