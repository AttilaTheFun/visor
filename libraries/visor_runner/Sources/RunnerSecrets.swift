/// Where the Runner keeps its secrets (docs/co-tenancy.md): each container
/// server's password and MCP token. The app gives its own store: the
/// keychain in a notarized build, its data folder in a debug one.
public protocol RunnerSecrets: Sendable {
    func value(_ name: String) -> String?
    /// Keeps a value, or forgets it (nil).
    func set(_ name: String, _ value: String?)
}
