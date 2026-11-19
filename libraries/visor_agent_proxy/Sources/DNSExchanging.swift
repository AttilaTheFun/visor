// How a query reaches an upstream resolver and its answer comes back: over
// the network (NIODNSExchange), or a test's stand-in.

/// One query to one upstream resolver, and its answer.
public protocol DNSExchanging: Sendable {
    /// The answer `upstream` gives `query`, under the query's own id; throws
    /// on a timeout or a network error.
    func exchange(_ query: DNSMessage, with upstream: DNSUpstream, timeout: Duration) async throws -> DNSMessage
}
