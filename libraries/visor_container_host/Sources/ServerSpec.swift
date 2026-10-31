import Foundation

/// What a container server is (docs/co-tenancy.md, the container host's
/// interface): its folder's `server.json`, written by the Runner and never
/// secret. Read field by field: a field left out is its default.
public struct ServerSpec: Codable, Equatable, Sendable {
    public var api = 2
    public var id: String
    public var name: String
    public var image: String
    public var cpus: Int?
    public var memoryBytes: Int64?
    public var diskBytes: Int64?
    public var mounts: [Mount] = []
    public var listen = Listen()
    public var mcp: [Endpoint] = []

    /// One of this computer's folders, seen in the container at `destination`.
    public struct Mount: Codable, Equatable, Sendable {
        public var source: String
        public var destination: String
        public var readOnly: Bool?
    }

    /// Where clients reach the container's server on this computer:
    /// loopback always, the LAN and VPNs as set.
    public struct Listen: Codable, Equatable, Sendable {
        public var port = 7440
        public var lan = false
        public var vpn = false

        public init() {}
    }

    /// An MCP server the container's agents may use, through the host: its
    /// headers (a value may name the session, `$SESSION_ID`) and the names
    /// of those whose values are secrets, kept by the host (`credentials`).
    public struct Endpoint: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var headers: [String: String] = [:]
        public var secretHeaders: [String] = []
    }

    public init(id: String, name: String, image: String) {
        self.id = id
        self.name = name
        self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api = try c.decodeIfPresent(Int.self, forKey: .api) ?? 2
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        image = try c.decode(String.self, forKey: .image)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        diskBytes = try c.decodeIfPresent(Int64.self, forKey: .diskBytes)
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        listen = try c.decodeIfPresent(Listen.self, forKey: .listen) ?? Listen()
        mcp = try c.decodeIfPresent([Endpoint].self, forKey: .mcp) ?? []
    }

    /// The spec in a container server's folder.
    public static func read(_ folder: URL) throws -> ServerSpec {
        try JSONDecoder().decode(ServerSpec.self, from: Data(contentsOf: folder.appendingPathComponent("server.json")))
    }

    /// The container's name, made of the server's id: a letter first, and
    /// nothing but letters, digits and `-`.
    public var containerName: String {
        "visor-server-" + String(id.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
