/// Where the Runner keeps its secrets (docs/co-tenancy.md): the MCP
/// servers' secret headers and each Visor server's token for the proxy.
public protocol RunnerSecrets: Sendable {
    func value(_ name: String) -> String?
    /// Keeps a value, or forgets it (nil).
    func set(_ name: String, _ value: String?)
}
