// What an agent presents instead of the password: its session's own token,
// so that one session's agent can't ask, or answer an approval, as another.
// Builds before 0.60 gave every agent one token, the server's; an agent
// such a build left under its host still holds it, and is let in with it
// as its own session until it is gone.

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// Where the sessions' tokens are kept with the secrets, as one JSON
    /// object of session id to token.
    static let sessionAgentTokensKey = "sessionAgentTokens"

    /// The shared token as kept, made the first time. Needed only for the
    /// agents builds before 0.60 left under their hosts: once no server
    /// can have one left, it goes.
    static func keptSharedAgentToken() -> String {
        if let kept = secrets.get("agentToken"), !kept.isEmpty { return kept }
        let made = UUID().uuidString
        secrets.set("agentToken", made)
        return made
    }

    /// The sessions' tokens as kept (none the first time).
    static func keptSessionAgentTokens() -> [String: String] {
        guard let kept = secrets.get(sessionAgentTokensKey), let data = kept.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }

    /// The session's own token, made and kept the first time it is asked
    /// for (the session's first agent).
    func agentToken(for session: String) -> String {
        if let kept = sessionAgentTokens[session] { return kept }
        let made = UUID().uuidString
        sessionAgentTokens[session] = made
        keepSessionAgentTokens()
        return made
    }

    /// Forgets an ended session's token: nothing may present it again.
    func forgetAgentToken(of session: String) {
        guard sessionAgentTokens.removeValue(forKey: session) != nil else { return }
        keepSessionAgentTokens()
    }

    /// The session `id` names, when `token` is its agent's: its own, or
    /// the shared one while the agent an earlier build left it runs.
    func agentSession(_ id: String?, presenting token: String?) -> SessionRecord? {
        guard let id, let token, !token.isEmpty, let record = session(id) else { return nil }
        if let own = sessionAgentTokens[id], own == token { return record }
        if token == sharedAgentToken, holdsSharedToken(record) { return record }
        return nil
    }

    /// Whether `token` is an agent's: a kept session's own, or the shared
    /// one while any session's agent from an earlier build still runs.
    func isAgentToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if sessions.contains(where: { !$0.info.archived && sessionAgentTokens[$0.info.id] == token }) { return true }
        return token == sharedAgentToken && sessions.contains { holdsSharedToken($0) }
    }

    /// Whether the session's agent is still the one an earlier build left
    /// under its host with the shared token.
    func holdsSharedToken(_ record: SessionRecord) -> Bool {
        guard let legacy = record.sharedTokenChild else { return false }
        return (record.process as? HostableProcess)?.hostedChild === legacy
    }

    private func keepSessionAgentTokens() {
        guard let data = try? JSONEncoder().encode(sessionAgentTokens) else { return }
        Self.secrets.set(Self.sessionAgentTokensKey, String(decoding: data, as: UTF8.self))
    }
}
