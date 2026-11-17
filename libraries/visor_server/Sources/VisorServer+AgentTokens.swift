// What a native session's agent presents instead of the password: a JWT
// for `visor.session` whose `sub` is its session (AgentTokens), so one
// session's agent can't ask, or answer an approval, as another. The
// envelope's own `client` or `session` must be the token's `sub`, and the
// session must exist and not be archived. Never a REST credential: the
// REST side refuses every agent's token (VisorServer+Access).
//
// Agents started before this build hold older tokens, taken only as their
// own session and only while that agent (left under its host by the build
// that started it) runs: the shared token of 0.59 and earlier, and the
// random per-session tokens of 0.60 and 0.61 (#421, #441). Once each such
// agent is gone, its session's agent holds a JWT.

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// Where the sessions' random tokens of 0.60 and 0.61 are kept with the
    /// secrets, as one JSON object of session id to token: read, never
    /// added to.
    static let sessionAgentTokensKey = "sessionAgentTokens"

    /// The shared token as kept, if a build before 0.60 kept one: only the
    /// agents such a build left under their hosts hold it.
    static func keptSharedAgentToken() -> String? {
        secrets.get("agentToken").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The sessions' random tokens as kept (none once no agent holds one).
    static func keptSessionAgentTokens() -> [String: String] {
        guard let kept = secrets.get(sessionAgentTokensKey), let data = kept.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }

    /// A new token for the session's native agent: a JWT for
    /// `visor.session`, acting as `session` alone, for a day.
    func agentToken(for session: String) -> String {
        agentTokens.mint(.session, session: session)
    }

    /// Forgets an ended session's old random token, and its token file:
    /// its JWTs are refused from now on, since its session is gone.
    func forgetAgentToken(of session: String) {
        removeSessionTokenFile(of: session)
        guard sessionAgentTokens.removeValue(forKey: session) != nil else { return }
        keepSessionAgentTokens()
    }

    /// What an agent's ask needs its token to allow: the passed-on MCP
    /// servers, or the sessions' messages.
    static func scope(of envelope: Envelope) -> AgentTokenScope {
        switch envelope.mode {
        case "mcp_tools", "mcp_call": .mcp
        default: .messages
        }
    }

    /// The session `id` names, when `token` is its agent's and allows
    /// `scope`: a JWT whose `sub` is `id`, or an older token while the
    /// agent an earlier build started with it runs. Never an archived
    /// session.
    func agentSession(_ id: String?, presenting token: String?, for scope: AgentTokenScope) -> SessionRecord? {
        guard let id, let token, !token.isEmpty, let record = session(id), !record.info.archived else { return nil }
        if JWT.isShaped(token) {
            guard case .success(let claims) = agentTokens.verify(token, as: .session, scope: scope), claims.sub == id else { return nil }
            return record
        }
        if holdsRandomToken(record), SecretToken.same(token, sessionAgentTokens[id]) { return record }
        if holdsSharedToken(record), SecretToken.same(token, sharedAgentToken) { return record }
        return nil
    }

    /// Whether `token` is an agent's: a JWT of this server's (a session's
    /// or a runner's agent's, expired or not), or an older token one of
    /// its agents still holds. What the REST side refuses as such.
    func isAgentToken(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        if JWT.isShaped(token) { return agentTokens.isAgentToken(token) }
        if sessions.contains(where: { holdsRandomToken($0) && SecretToken.same(token, sessionAgentTokens[$0.info.id]) }) { return true }
        return SecretToken.same(token, sharedAgentToken) && sessions.contains { holdsSharedToken($0) }
    }

    /// Whether the session's agent is still the one an earlier build left
    /// under its host with the shared token.
    func holdsSharedToken(_ record: SessionRecord) -> Bool {
        guard let legacy = record.sharedTokenChild else { return false }
        return (record.process as? HostableProcess)?.hostedChild === legacy
    }

    /// Whether the session's agent is still the one 0.60 or 0.61 left under
    /// its host with its session's random token.
    func holdsRandomToken(_ record: SessionRecord) -> Bool {
        guard let legacy = record.randomTokenChild else { return false }
        return (record.process as? HostableProcess)?.hostedChild === legacy
    }

    private func keepSessionAgentTokens() {
        guard let data = try? JSONEncoder().encode(sessionAgentTokens) else { return }
        Self.secrets.set(Self.sessionAgentTokensKey, sessionAgentTokens.isEmpty ? nil : String(decoding: data, as: UTF8.self))
    }
}
