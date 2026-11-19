// Which resolvers a name is asked of, in order (docs/server-proxy.md in
// Visor, "Every agent's proxy": DNS split by name).

/// The resolver's split by name: the tailnet's names to Tailscale's
/// resolver alone (a tailnet name never leaves for a public resolver), and
/// only where it is named (`tailnet`): by default the agent proxy answers
/// them itself, no such name (NCH's review of #414: its agents' egress
/// reaches no tailnet peer unless allowed, so their names stay the Mac's).
/// Every other name to the computer's own resolvers, then the fallbacks.
public struct DNSRoutes: Sendable, Equatable {
    /// The suffixes that are the tailnet's (`ts.net` covers MagicDNS's
    /// `<machine>.<tailnet>.ts.net`), matched on a label's boundary.
    public var tailnetSuffixes: [String]
    /// Who answers for the tailnet's names; none: nobody, they are withheld.
    public var tailnet: [DNSUpstream]
    /// The computer's own resolvers (SystemResolvers).
    public var system: [DNSUpstream]
    /// Asked when the computer's own fail, time out or refuse.
    public var fallbacks: [DNSUpstream]

    public init(tailnetSuffixes: [String] = ["ts.net"], tailnet: [DNSUpstream] = [],
                system: [DNSUpstream], fallbacks: [DNSUpstream] = DNSUpstream.publicFallbacks) {
        self.tailnetSuffixes = tailnetSuffixes.map { $0.lowercased().trimmingDots() }.filter { !$0.isEmpty }
        self.tailnet = tailnet
        self.system = system
        self.fallbacks = fallbacks
    }

    /// Whether `name` is the tailnet's.
    public func isTailnet(_ name: String) -> Bool {
        let name = name.lowercased().trimmingDots()
        return tailnetSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Whether `name` is the tailnet's and nobody is to be asked of it.
    public func withholds(_ name: String) -> Bool { tailnet.isEmpty && isTailnet(name) }

    /// The resolvers to ask for `name`, in order, each once.
    public func upstreams(for name: String) -> [DNSUpstream] {
        var seen = Set<DNSUpstream>()
        let all = isTailnet(name) ? tailnet : system + fallbacks
        return all.filter { seen.insert($0).inserted }
    }
}

extension String {
    /// Without a leading or trailing dot ("ts.net." → "ts.net").
    fileprivate func trimmingDots() -> String {
        var text = Substring(self)
        while text.hasPrefix(".") { text = text.dropFirst() }
        while text.hasSuffix(".") { text = text.dropLast() }
        return String(text)
    }
}
