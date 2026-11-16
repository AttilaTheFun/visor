// Each agent's own token (agent_protocol's Job.token): minted when its job
// is queued, given to the runner that claims it (which hands it to its
// wrapper in AGENT_TOKEN), and asked of every call made for the agent:
// the wrapper's Connect, Conversation and Report, and the runner's Renew
// and Report (AgentBearer). A token is its agent's alone, so it says which
// session a wrapper is: one agent's can't dial in, report or renew as
// another's. Kept with the server's secrets (never in jobs.json or the
// log), so a restart keeps its runners' agents; gone with its agent's job
// (forget, stopJobs).

import Foundation
import VisorServer

extension JobQueue {
    /// What a call shown `bearer` for `agent` may do.
    enum Access: Equatable {
        /// The agent's own token.
        case granted
        /// This dispatcher holds no token for the agent (its job is gone,
        /// or was never here).
        case unknown
        /// A token missing, or not the agent's: why.
        case refused(String)
    }

    /// Where the tokens are kept among the server's secrets: one JSON
    /// object of agent id to token.
    static let tokensKey = "runnerAgentTokens"

    /// The tokens a secrets store kept, if any.
    static func keptTokens(_ secrets: (any SecretStore)?) -> [String: String] {
        guard let kept = secrets?.get(tokensKey), let data = kept.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }

    /// A new token: 32 random bytes, as hex.
    nonisolated static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// The agent's token, minted (and kept) the first time it is asked for.
    func token(for agent: String) -> String {
        let id = Self.key(agent)
        if let held = tokens[id] { return held }
        let made = Self.mintToken()
        tokens[id] = made
        keepTokens()
        return made
    }

    /// The agent's token gone: nothing may present it again.
    func forgetToken(of agent: String) {
        guard tokens.removeValue(forKey: Self.key(agent)) != nil else { return }
        keepTokens()
    }

    /// Whether a call for `agent` that shows `bearer` is the agent's.
    func access(_ agent: String, bearer: String?) -> Access {
        access(agent, bearers: bearer.map { [$0] } ?? [])
    }

    /// Whether a call for `agent` that shows `bearers` is the agent's: one
    /// of them is its token (a runner's renewal may show its own beside it).
    func access(_ agent: String, bearers: [String]) -> Access {
        let id = Self.key(agent)
        guard let held = tokens[id] else { return .unknown }
        let shown = bearers.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return .refused("The call shows no token (authorization: Bearer <Job.token>).") }
        // Each compared in constant time (RunnerTokens.same): how much of
        // a guess matched takes no longer to find.
        guard !shown.contains(where: { RunnerTokens.same($0, held) }) else { return .granted }
        if shown.contains(where: { bearer in tokens.values.contains { RunnerTokens.same(bearer, $0) } }) {
            return .refused("That token is another agent's.")
        }
        return .refused("That token isn't this agent's.")
    }

    /// The runner whose claim on `agent`'s job is held, if one is.
    func holder(of agent: String) -> String? {
        claimed[Self.key(agent)]?.runner
    }

    private func keepTokens() {
        guard let secrets else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tokens) else { return }
        secrets.set(Self.tokensKey, tokens.isEmpty ? nil : String(decoding: data, as: UTF8.self))
    }
}
