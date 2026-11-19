// One resolver the agent proxy's asks: an address and a port.

/// A resolver upstream of the agent proxy's: an IPv4 or IPv6 address and its
/// port (53 unless said).
public struct DNSUpstream: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(_ host: String, port: Int = 53) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Tailscale's resolver, which knows the tailnet's names (MagicDNS).
    public static let tailscale = DNSUpstream("100.100.100.100")
    /// The fallbacks when the computer's own resolvers fail: Cloudflare's,
    /// then Google's.
    public static let publicFallbacks = [DNSUpstream("1.1.1.1"), DNSUpstream("8.8.8.8")]
}
