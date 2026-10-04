// How each agent is paid for on this computer and how near its limits it
// is: what its sessions last said (Claude Code's rate-limit events, Codex's
// account reads, the openrouter CLI's key), kept on disk beside the
// sessions and sent with the agent's catalog — so a client sees it before
// a session of that agent has run since the server started. A change goes
// out on its own, not with the catalogs, which can be long.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What is known of an agent's account.
    func account(for agent: AgentKind) -> AgentAccount? {
        if knownAccounts == nil { knownAccounts = Self.keptAccounts() }
        return knownAccounts?[agent]
    }

    /// An agent said how it is paid for.
    func keepPlan(_ plan: String, subscription: Bool, for agent: AgentKind) {
        var account = account(for: agent) ?? AgentAccount(updated: 0)
        guard account.plan != plan || account.subscription != subscription else { return }
        // A subscription's windows are not a key's: what is said of the
        // key comes after.
        if account.subscription, !subscription { account.limits = [] }
        account.plan = plan
        account.subscription = subscription
        keep(account, for: agent)
    }

    /// An agent said how near its limits it is.
    func keepLimits(_ limits: [UsageLimit], for agent: AgentKind) {
        var account = account(for: agent) ?? AgentAccount(updated: 0)
        // The same again is news only of when it was true: worth telling
        // every few minutes, not every turn.
        guard account.limits != limits || Date().timeIntervalSince1970 - account.updated > 5 * 60 else { return }
        account.limits = limits
        keep(account, for: agent)
    }

    private func keep(_ account: AgentAccount, for agent: AgentKind) {
        var account = account
        account.updated = Date().timeIntervalSince1970
        knownAccounts?[agent] = account
        let byAgent = Dictionary(uniqueKeysWithValues: (knownAccounts ?? [:]).map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(byAgent) { try? data.write(to: Self.accountsURL, options: .atomic) }
        let envelope = Envelope.account(account, of: agent)
        for connection in connections.values where connection.authenticated { connection.send(envelope) }
    }

    static func keptAccounts() -> [AgentKind: AgentAccount] {
        guard let data = try? Data(contentsOf: accountsURL),
              let byAgent = try? JSONDecoder().decode([String: AgentAccount].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: byAgent.compactMap { key, value in AgentKind(rawValue: key).map { ($0, value) } })
    }
}
