// The resolver's decision: which upstreams a query goes to, in order, and
// which answer comes back. Moved from MultiPass (Logan, 2026-11-14).

/// Answers a query by asking the upstreams its name's route names, in
/// order. An answer is taken when it says something about the name (no
/// error, or no such name); a server failure, a refusal, a timeout or a
/// network error moves on to the next. When none answers, the query gets a
/// server failure of the agent proxy's own.
public struct DNSForwarder: Sendable {
    public var routes: @Sendable () -> DNSRoutes
    public var exchange: any DNSExchanging
    /// How long each upstream has.
    public var timeout: Duration
    /// A line for each query the first upstream didn't answer: the name,
    /// who answered after whom (or that none did). Names only, never the
    /// answers; a query answered at once isn't logged.
    public var log: @Sendable (String) -> Void

    public init(routes: @escaping @Sendable () -> DNSRoutes, exchange: any DNSExchanging,
                timeout: Duration = .seconds(2), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.routes = routes
        self.exchange = exchange
        self.timeout = timeout
        self.log = log
    }

    /// The answer to `query`, under its id; nil for something that isn't a
    /// query (a response, or bytes that don't parse), which is dropped.
    public func answer(_ query: DNSMessage) async -> DNSMessage? {
        guard !query.isResponse else { return nil }
        let routes = self.routes()
        if routes.withholds(query.name) {
            log("dns \(query.name): the tailnet's, withheld")
            return query.answer(.nameError)
        }
        var tried: [String] = []
        for upstream in routes.upstreams(for: query.name) {
            do {
                let answer = try await exchange.exchange(query, with: upstream, timeout: timeout)
                guard answer.id == query.id, answer.isResponse else {
                    tried.append("\(upstream) mismatched")
                    continue
                }
                switch answer.code {
                case .noError?, .nameError?:
                    if !tried.isEmpty {
                        log("dns \(query.name): \(upstream) \(answer.code == .noError ? "answered" : "no such name")"
                            + " (after \(tried.joined(separator: ", ")))")
                    }
                    return answer
                default:
                    tried.append("\(upstream) \(answer.code.map { "\($0)" } ?? "code \(answer.bytes[3] & 0x0F)")")
                }
            } catch {
                tried.append("\(upstream) \(error is DNSTimeout ? "timed out" : "failed")")
            }
        }
        log("dns \(query.name): no answer" + (tried.isEmpty ? " (no resolvers)" : " (\(tried.joined(separator: ", ")))"))
        return query.answer(.serverFailure)
    }
}

// The forwarder answers a DNSServer's queries.
extension DNSForwarder: DNSAnswering {}
