/// A Visor server a session signed in to the Runner may reach, as
/// `GET /runner/v1/servers` lists it: the Mac's own, or one in a container.
public struct RunnerServerInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case mac, container }

    /// How the Runner names it (runner.json's `servers`).
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The servers a Runner serves, as its configuration has them: one with
    /// a front (a port for its clients) runs in a container, any other is
    /// the Mac's.
    public static func listed(in config: RunnerConfig) -> [RunnerServerInfo] {
        let fronted = Set(config.fronts.map(\.name))
        return config.servers.map { RunnerServerInfo(id: $0, name: $0, kind: fronted.contains($0) ? .container : .mac) }
    }
}
