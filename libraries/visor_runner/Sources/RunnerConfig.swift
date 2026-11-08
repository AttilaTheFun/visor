import Foundation

/// What the Runner's agent is told that isn't secret (docs/co-tenancy.md):
/// `runner.json` in the Runner's data folder. The MCP servers its proxy
/// passes calls on to, the proxy's port, the Visor servers it serves, each
/// by a name (its token is a secret), the fronts its client proxy keeps
/// for them, and the port of its GitHub proxy (none: off).
public struct RunnerConfig: Codable, Equatable, Sendable {
    public var mcpPort = 7439
    public var endpoints: [MCPProxy.Endpoint] = []
    public var servers: [String] = []
    public var fronts: [ClientProxy.Front] = []
    public var githubProxyPort: Int?
    /// The GitHub App agents act as, and its installation, whose tokens the
    /// GitHub proxy mints with the App's key (a secret). Without them
    /// GitHub's hosts are tunnels too.
    public var githubAppID: String?
    public var githubInstallation: String?
    /// The Runner's one user (docs/runner-accounts.md), its password's hash
    /// a secret (RunnerPasswordAuth), and the port its side for clients
    /// (RunnerAPI) listens on (none: off).
    public var user: String?
    public var apiPort: Int?
    /// Names its certificate is for besides `localhost`, loopback and the
    /// Mac's own (RunnerIdentity): an address or a name clients reach it by.
    public var apiNames: [String] = []
    /// Where the Runner reaches each server it passes clients' requests on
    /// to (`server reach`): its name, then `host:port`. The server's
    /// password is a secret (RunnerAPIServer.passwordSecret).
    public var reaches: [String: String] = [:]

    public init(mcpPort: Int = 7439, endpoints: [MCPProxy.Endpoint] = [], servers: [String] = [], fronts: [ClientProxy.Front] = [],
                githubProxyPort: Int? = nil) {
        self.mcpPort = mcpPort
        self.endpoints = endpoints
        self.servers = servers
        self.fronts = fronts
        self.githubProxyPort = githubProxyPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpPort = try c.decodeIfPresent(Int.self, forKey: .mcpPort) ?? 7439
        endpoints = try c.decodeIfPresent([MCPProxy.Endpoint].self, forKey: .endpoints) ?? []
        servers = try c.decodeIfPresent([String].self, forKey: .servers) ?? []
        fronts = try c.decodeIfPresent([ClientProxy.Front].self, forKey: .fronts) ?? []
        githubProxyPort = try c.decodeIfPresent(Int.self, forKey: .githubProxyPort)
        githubAppID = try c.decodeIfPresent(String.self, forKey: .githubAppID)
        githubInstallation = try c.decodeIfPresent(String.self, forKey: .githubInstallation)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort)
        apiNames = try c.decodeIfPresent([String].self, forKey: .apiNames) ?? []
        reaches = try c.decodeIfPresent([String: String].self, forKey: .reaches) ?? [:]
    }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("runner.json") }

    public static func read(_ folder: URL) -> RunnerConfig? {
        (try? Data(contentsOf: file(folder))).flatMap { try? JSONDecoder().decode(RunnerConfig.self, from: $0) }
    }

    public func write(_ folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.file(folder), options: .atomic)
    }
}
