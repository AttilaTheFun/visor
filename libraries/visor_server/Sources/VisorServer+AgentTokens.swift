// What an agent presents instead of the password: its session's own token,
// so that one session's agent can't ask, or answer an approval, as another.
//
// What it doesn't do (yet): a session's token is still a REST credential,
// the same as the password (`authorized`, VisorServer+Access.swift), so
// session A's agent can `POST /api/sessions/B/…` and act on B over REST:
// Logan (2026-11-14) let sessions running natively use the admin side. And
// every native agent runs as the same Unix user, which can read the others'
// environments and Visor's secrets, so per-session tokens keep sessions
// apart by name (on the protocol's `agent` and `approval_request`), not
// against an agent that sets out to cross. The next step, for Logan to
// approve: scope REST by the session token (a session's token acts on its
// own session only, the admin routes keep the password).
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

    /// The session's own token, made (SecretToken: 32 random bytes) and
    /// kept the first time it is asked for (the session's first agent).
    func agentToken(for session: String) -> String {
        if let kept = sessionAgentTokens[session] { return kept }
        let made = SecretToken.mint()
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
    /// the shared one while the agent an earlier build left it runs. Never
    /// an archived session, as `isAgentToken` takes none. Compared in
    /// constant time (SecretToken.same).
    func agentSession(_ id: String?, presenting token: String?) -> SessionRecord? {
        guard let id, let token, !token.isEmpty, let record = session(id), !record.info.archived else { return nil }
        if SecretToken.same(token, sessionAgentTokens[id]) { return record }
        if SecretToken.same(token, sharedAgentToken), holdsSharedToken(record) { return record }
        return nil
    }

    /// Whether `token` is an agent's: a live (unarchived) session's own,
    /// or the shared one while any session's agent from an earlier build
    /// still runs. Any such token is also a REST credential (`authorized`):
    /// see the top of this file.
    func isAgentToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if sessions.contains(where: { !$0.info.archived && SecretToken.same(token, sessionAgentTokens[$0.info.id]) }) { return true }
        return SecretToken.same(token, sharedAgentToken) && sessions.contains { holdsSharedToken($0) }
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
