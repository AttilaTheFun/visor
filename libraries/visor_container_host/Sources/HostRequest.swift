/// What `create` is given (docs/container-host.md): the container's image,
/// size, this computer's folders and its own disks. Read field by field: a
/// field left out is its default, not an unreadable request.
struct HostRequest: Codable, Equatable, Sendable {
    var name: String
    var image: String
    var cpus: Int?
    var memoryBytes: Int64?
    var mounts: [Mount] = []
    var volumes: [Volume] = []
    var environment: [String: String] = [:]
    var rosetta = false
    var labels: [String: String] = [:]

    struct Mount: Codable, Equatable, Sendable {
        var source: String
        var destination: String
        var readOnly: Bool?
    }

    struct Volume: Codable, Equatable, Sendable {
        var name: String
        var destination: String
        var sizeBytes: Int64
    }

    init(name: String, image: String) {
        self.name = name
        self.image = image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decode(String.self, forKey: .image)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}
