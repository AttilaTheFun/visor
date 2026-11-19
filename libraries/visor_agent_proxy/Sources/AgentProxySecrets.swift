// Where agent-proxy's own secrets are kept: its authority's key and
// certificate, the relay's token, the auth token the GitHub gate attaches,
// and the native MCP proxy's token and secret headers, each one of Visor's
// secrets (the keychain on a Mac, the secrets file elsewhere). AgentProxy
// itself knows no store: its host (VisorAgentProxyHost) reads them through
// Visor's SecretStore, its `agent-proxy/` items alone, and hands them in as
// this; a test gives its own.

import Foundation

/// The seam between AgentProxy and the Keychain: items by their accounts.
public protocol AgentProxySecrets: Sendable {
    /// The item kept as `account`, or nil when there's none. Throws when
    /// the store didn't answer: never taken for "none", which would have a
    /// caller make a new one over what's there.
    func item(_ account: String) throws -> Data?
    /// `data` kept as `account`'s item, in place of what was.
    func setItem(_ account: String, _ data: Data) throws
}
