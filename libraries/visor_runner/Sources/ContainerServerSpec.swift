import Foundation

/// What a container server is (docs/co-tenancy.md): `server.json` in its
/// folder of the Runner's, never secret. Read field by field: a field left
/// out is its default.
public struct ContainerServerSpec: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var cpus: Int?
    public var memoryBytes: Int64?
    public var diskBytes: Int64?
    public var mounts: [Mount] = []
    public var listen = Listen()
    /// The port of this computer's loopback the container's server port is
    /// published to, which only the Runner's proxy reaches (by default the
    /// clients' port plus 10000).
    public var loopbackPort: Int?
    /// Stopped from the Runner: its container stopped, and left so until
    /// it is started again.
    public var stopped = false

    /// One of this computer's folders, seen in the container at
    /// `destination` (its own path, by default).
    public struct Mount: Codable, Equatable, Sendable {
        public var source: String
        public var destination: String
        public var readOnly: Bool?

        public init(source: String, destination: String? = nil, readOnly: Bool? = nil) {
            self.source = source
            self.destination = destination ?? source
            self.readOnly = readOnly
        }
    }

    /// Where clients reach the server: the Runner's port for it, on loopback
    /// alone or, with the LAN or a VPN, on every interface.
    public struct Listen: Codable, Equatable, Sendable {
        public var port = 7440
        public var lan = false
        public var vpn = false

        public init(port: Int = 7440, lan: Bool = false, vpn: Bool = false) {
            self.port = port
            self.lan = lan
            self.vpn = vpn
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7440
            lan = try c.decodeIfPresent(Bool.self, forKey: .lan) ?? false
            vpn = try c.decodeIfPresent(Bool.self, forKey: .vpn) ?? false
        }
    }

    public init(id: String, name: String, image: String) {
        self.id = id
        self.name = name
        self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        image = try c.decode(String.self, forKey: .image)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        diskBytes = try c.decodeIfPresent(Int64.self, forKey: .diskBytes)
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        listen = try c.decodeIfPresent(Listen.self, forKey: .listen) ?? Listen()
        loopbackPort = try c.decodeIfPresent(Int.self, forKey: .loopbackPort)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("server.json") }

    public static func read(_ folder: URL) throws -> ContainerServerSpec {
        try JSONDecoder().decode(ContainerServerSpec.self, from: Data(contentsOf: file(folder)))
    }

    public func write(_ folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.file(folder), options: .atomic)
    }

    /// Where the container's server port is published on loopback.
    public var publishedPort: Int { loopbackPort ?? listen.port + 10000 }

    /// The container's name, made of the server's id: a letter first, and
    /// nothing but letters, digits and `-`.
    public var containerName: String {
        "visor-server-" + String(id.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}
