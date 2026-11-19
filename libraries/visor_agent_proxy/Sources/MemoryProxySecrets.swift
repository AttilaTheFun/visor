// agent-proxy's secrets in memory, for tests.

import Foundation

/// Secrets in memory: a test's, never the helper's.
public final class MemoryProxySecrets: AgentProxySecrets {
    private let items: Locked<[String: Data]>

    public init(_ items: [String: Data] = [:]) { self.items = Locked(items) }

    public func item(_ account: String) throws -> Data? { items.withLock { $0[account] } }

    public func setItem(_ account: String, _ data: Data) throws { items.withLock { $0[account] = data } }

    /// Every account kept.
    public var accounts: [String] { items.withLock { $0.keys.sorted() } }
}
