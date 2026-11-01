import Foundation

/// What the Runner's agent is told that isn't secret (docs/co-tenancy.md):
/// `runner.json` in the Runner's data folder. The MCP servers its proxy
/// passes calls on to, the proxy's port, and the Visor servers it serves,
/// each by a name (its token is a secret).
public struct RunnerConfig: Codable, Equatable, Sendable {
    public var mcpPort = 7439
    public var endpoints: [MCPProxy.Endpoint] = []
    public var servers: [String] = []

    public init(mcpPort: Int = 7439, endpoints: [MCPProxy.Endpoint] = [], servers: [String] = []) {
        self.mcpPort = mcpPort
        self.endpoints = endpoints
        self.servers = servers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpPort = try c.decodeIfPresent(Int.self, forKey: .mcpPort) ?? 7439
        endpoints = try c.decodeIfPresent([MCPProxy.Endpoint].self, forKey: .endpoints) ?? []
        servers = try c.decodeIfPresent([String].self, forKey: .servers) ?? []
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
