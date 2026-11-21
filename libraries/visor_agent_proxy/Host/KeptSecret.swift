// One of agent-proxy's secrets as the server keeps it now, read at most once
// a minute: one set (or replaced, or removed) with `agent-proxy secret-set`
// is taken within a minute without a restart, and the keychain isn't asked
// at each call. A store that didn't answer this once keeps the value read
// before: no secret is gone because a read failed. Never logged.

import Foundation
import Synchronization
import VisorServer

/// A secret, read again each minute.
public final class KeptSecret: Sendable {
    private let key: String
    private let secrets: any SecretStore
    private let every: TimeInterval
    private let state = Mutex<(read: Date, value: String?)>((.distantPast, nil))

    /// `name` is agent-proxy's own (`github-token`, `mcp/token`, …).
    public init(_ name: String, in secrets: any SecretStore, every: TimeInterval = 60) {
        key = AgentProxySettings.secretKey(name)
        self.secrets = secrets
        self.every = every
    }

    /// As kept now, trimmed; nil for none.
    public var value: String? {
        state.withLock { state in
            if Date().timeIntervalSince(state.read) >= every {
                state.read = Date()
                switch secrets.lookup(key) {
                case .found(let found):
                    let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.value = trimmed.isEmpty ? nil : trimmed
                case .absent: state.value = nil
                case .unreadable: break
                }
            }
            return state.value
        }
    }

    var isSet: Bool { value != nil }

    /// Whether `token` is it, compared in constant time; never with none.
    func admits(_ token: String) -> Bool {
        guard let expected = value else { return false }
        let given = Array(token.utf8), kept = Array(expected.utf8)
        guard given.count == kept.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, kept) { difference |= a ^ b }
        return difference == 0
    }
}
