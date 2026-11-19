// What MultiPass's runner.json said of the resolver (`dns listen`): where it
// listens, and how names are split. The agent proxy takes the split from
// server.json's `agentProxy.dns` (shireworks-agent-proxy) and listens
// nowhere (DNS over HTTPS through the relay). The computer's own resolvers
// aren't kept: they are /etc/resolv.conf's at each query, so a network
// change needs no restart.

/// The resolver's settings: off unless it listens somewhere.
public struct DNSSettings: Codable, Equatable, Sendable {
    /// The addresses it listens on: the containers' gateway (Shireworks'
    /// SHIREWORKS_HOST_ADDRESS, 192.168.128.1 on the MacBook) and loopback.
    public var hosts: [String]
    public var port: Int
    public var tailnetSuffixes: [String]
    /// Who answers for the tailnet's names: none by default, so they are
    /// withheld (DNSRoutes); `["100.100.100.100"]`, Tailscale's, to opt in.
    public var tailnet: [String]
    /// Asked when the computer's own resolvers fail.
    public var fallbacks: [String]

    public init(hosts: [String], port: Int = 53, tailnetSuffixes: [String] = ["ts.net"],
                tailnet: [String] = [], fallbacks: [String] = DNSUpstream.publicFallbacks.map(\.host)) {
        self.hosts = hosts
        self.port = port
        self.tailnetSuffixes = tailnetSuffixes
        self.tailnet = tailnet
        self.fallbacks = fallbacks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hosts: try c.decode([String].self, forKey: .hosts))
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        tailnetSuffixes = try c.decodeIfPresent([String].self, forKey: .tailnetSuffixes) ?? tailnetSuffixes
        tailnet = try c.decodeIfPresent([String].self, forKey: .tailnet) ?? tailnet
        fallbacks = try c.decodeIfPresent([String].self, forKey: .fallbacks) ?? fallbacks
    }

    /// The split, with `system` as the computer's own resolvers: by default
    /// /etc/resolv.conf's, less the addresses this resolver listens on.
    public func routes(system: [DNSUpstream]? = nil) -> DNSRoutes {
        DNSRoutes(tailnetSuffixes: tailnetSuffixes, tailnet: tailnet.map { DNSUpstream($0) },
                  system: system ?? SystemResolvers.current(excluding: Set(hosts)),
                  fallbacks: fallbacks.map { DNSUpstream($0) })
    }
}
