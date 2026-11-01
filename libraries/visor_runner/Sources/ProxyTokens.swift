/// The proxy's tokens and secret headers as the Runner keeps them
/// (docs/co-tenancy.md): each Visor server it serves has a token of its own,
/// which that server sends with each call (`MCPProxy.tokenHeader`); an
/// endpoint's secret header values never leave the Runner.
public enum ProxyTokens {
    /// Where a server's token is kept with the Runner's secrets.
    public static func key(server: String) -> String { "proxy-server \(server) token" }

    /// Where an endpoint's secret header's value is kept.
    public static func secretKey(endpoint: String, header: String) -> String { "mcp \(endpoint) \(header)" }

    /// A server's token, made the first time it is asked for.
    public static func token(for server: String, in secrets: RunnerSecrets) -> String {
        if let kept = secrets.value(key(server: server)) { return kept }
        let made = (0..<32).map { _ in String(UInt8.random(in: 0...255), radix: 16).leftPadded() }.joined()
        secrets.set(key(server: server), made)
        return made
    }

    /// Whether `token` is one of these servers'.
    public static func admits(_ token: String, servers: [String], in secrets: RunnerSecrets) -> Bool {
        !token.isEmpty && servers.contains { secrets.value(key(server: $0)) == token }
    }
}

private extension String {
    /// Two hex digits.
    func leftPadded() -> String { count < 2 ? "0" + self : self }
}
