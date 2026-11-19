// agent-proxy's secrets as AgentProxy takes them (AgentProxySecrets), read
// from and kept in the server's own store (the keychain on a Mac, under the
// server's service; the secrets file elsewhere): its `agent-proxy/` items
// alone, so nothing else the server keeps (its password, its signing keys)
// is reached through here. A store that couldn't be read throws, never
// taken for "none": the GitHub authority isn't made again over one there.

import Foundation
import VisorAgentProxy
import VisorServer

/// The server's secrets, agent-proxy's alone.
struct ProxySecretStore: AgentProxySecrets {
    /// Why an item couldn't be had.
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    let secrets: any SecretStore

    func item(_ account: String) throws -> Data? {
        guard account.hasPrefix(AgentProxySettings.secretPrefix) else { throw Refused(description: "\(account) isn't one of agent-proxy's") }
        switch secrets.lookup(account) {
        case .found(let value): return Data(value.utf8)
        case .absent: return nil
        case .unreadable(let why): throw Refused(description: "\(account) can't be read: \(why)")
        }
    }

    func setItem(_ account: String, _ data: Data) throws {
        guard account.hasPrefix(AgentProxySettings.secretPrefix) else { throw Refused(description: "\(account) isn't one of agent-proxy's") }
        secrets.set(account, String(decoding: data, as: UTF8.self))
    }
}
