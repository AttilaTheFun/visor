// What answers the queries a DNSServer takes: the agent proxy's forwarder
// (DNSForwarder). Moved from MultiPassBase (Logan, 2026-11-14).

/// Answers DNS queries.
public protocol DNSAnswering: Sendable {
    /// The answer to `query`, under its id; nil to drop it.
    func answer(_ query: DNSMessage) async -> DNSMessage?
}
