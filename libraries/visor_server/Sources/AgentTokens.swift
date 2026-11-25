// The agents' tokens: JWTs (compact JWS, HS256) this server mints and
// verifies with no table of them, only its signing keys (SigningKeys).
// A native session's agent holds one for `visor.session`; a runner's
// agent, through its wrapper, one for `visor.runner-agent` that names it
// (`agent`). Each acts as its `sub` session alone, for what its `scope`
// says, until its `exp`. Whether its session still exists, and isn't
// archived, is asked by whoever takes it (VisorServer+AgentTokens, the
// driver's JobQueue): this checks the token itself.

import Foundation

@MainActor
package final class AgentTokens {
    /// How long a native session's token lasts (it is re-minted hourly into
    /// its token file, VisorServer+SessionTokenFiles).
    package var sessionLifetime: TimeInterval = 24 * 3600
    /// How long a runner's agent's token lasts (refreshed over its driver
    /// stream before it ends: DriverMessage.token).
    package var runnerAgentLifetime: TimeInterval = 3600

    /// How long past its end a runner's agent's token is still taken, and
    /// only for its runner's Renew and Release (`withinGrace`): a day, as
    /// long as the longest-lived token (a session's) lasts and as long as a
    /// retired key verifies, so a token past its end is never worth more
    /// than a live one of any audience. A runner's job outlasting its
    /// claim's token by more than this loses its claim (its renewal is
    /// answered with no claim, so its runner ends its agent) and is given
    /// out again with a fresh token. This window is a stopgap: the real fix
    /// is agent_protocol's RenewResponse.token, a fresh token on each
    /// renewal, which the runner shows from then on; once Shireworks'
    /// runner reads it, this goes.
    nonisolated package static let expiredTokenGrace: TimeInterval = 24 * 3600

    /// How long a token for `audience` lasts.
    package func lifetime(of audience: AgentTokenAudience) -> TimeInterval {
        switch audience {
        case .session: sessionLifetime
        case .runnerAgent: runnerAgentLifetime
        }
    }

    /// The keys tokens are signed with.
    package let keys: SigningKeys
    /// This server's id: every token's `iss`.
    package var issuer: String

    package init(secrets: any SecretStore, issuer: String) {
        keys = SigningKeys(secrets: secrets)
        self.issuer = issuer
    }

    /// A new token for `audience`, acting as `session` (and, for a runner's
    /// agent, as `agent`), signed with the current key. `scope`: less than
    /// the audience may do (a container agent's token for the MCP
    /// pass-through: `.mcp` alone); never more.
    package func mint(_ audience: AgentTokenAudience, session: String, agent: String? = nil, scope: [AgentTokenScope]? = nil,
                      now: Date = Date()) -> String {
        let issued = Int(now.timeIntervalSince1970)
        let allowed = scope.map { asked in audience.scope.filter { asked.contains($0) } } ?? audience.scope
        let claims = AgentTokenClaims(iss: issuer, aud: audience.rawValue, sub: session,
                                      agent: audience == .runnerAgent ? agent.map(Self.agentKey) : nil,
                                      scope: allowed.map(\.rawValue), iat: issued, exp: issued + Int(lifetime(of: audience)),
                                      jti: UUID().uuidString.lowercased())
        guard let current = keys.current else {
            VisorServer.log("agent tokens: none minted for \(session): \(keys.problem ?? "no signing key")")
            return ""
        }
        return (try? JWT.sign(claims, key: current.key, kid: current.kid)) ?? ""
    }

    /// `token`'s claims, when it is this server's, for `audience`, unexpired
    /// (or, `withinGrace`, ended less than `expiredTokenGrace` ago), naming
    /// `agent` (a runner's agent's), and allowed `scope`; else why not. Its
    /// session is the caller's to ask.
    ///
    /// `withinGrace` is the dispatcher's, for a runner's Renew and its
    /// Release report alone: the runner shows the token its claim gave it,
    /// which it can't refresh until it reads agent_protocol's
    /// RenewResponse.token. A token signed by a key past its life
    /// (SigningKeys: an ordinary rotation's, a day on) is taken then as an
    /// expired one is, and only then; one signed by a key an emergency
    /// rotation dropped never is.
    package func verify(_ token: String, as audience: AgentTokenAudience, agent: String? = nil, scope: AgentTokenScope? = nil,
                        now: Date = Date(), withinGrace: Bool = false) -> Result<AgentTokenClaims, AgentTokenRefusal> {
        guard let parts = JWT.parts(of: token) else { return .failure(.malformed) }
        let liveKey = keys.key(parts.header.kid, now: now)
        guard let key = liveKey ?? (withinGrace ? keys.key(parts.header.kid, now: now, withinGrace: true) : nil) else {
            return .failure(.unknownKey)
        }
        guard JWT.verify(parts, key: key) else { return .failure(.badSignature) }
        guard let claims = try? JSONDecoder().decode(AgentTokenClaims.self, from: parts.payload) else { return .failure(.malformed) }
        guard claims.iss == issuer else { return .failure(.wrongIssuer) }
        guard claims.aud == audience.rawValue else { return .failure(.wrongAudience) }
        let ended = Double(claims.exp)
        if liveKey == nil || ended <= now.timeIntervalSince1970 {
            guard withinGrace, now.timeIntervalSince1970 < ended + Self.expiredTokenGrace else { return .failure(.expired) }
        }
        switch audience {
        case .session:
            guard claims.agent == nil else { return .failure(.wrongAudience) }
        case .runnerAgent:
            guard let named = claims.agent, let agent, named == Self.agentKey(agent) else { return .failure(.wrongAgent) }
        }
        if let scope, !claims.allows(scope) { return .failure(.outOfScope) }
        return .success(claims)
    }

    /// When `token` (one of this server's, of any audience) ends, if it
    /// is one.
    package func expiry(of token: String) -> Date? {
        guard let parts = JWT.parts(of: token), let key = keys.key(parts.header.kid), JWT.verify(parts, key: key),
              let claims = try? JSONDecoder().decode(AgentTokenClaims.self, from: parts.payload), claims.iss == issuer else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(claims.exp))
    }

    /// Whether `token` is one of this server's agents' tokens, of either
    /// audience, expired or not: what the REST side refuses as such.
    package func isAgentToken(_ token: String) -> Bool {
        expiry(of: token) != nil
    }

    /// An agent's id as tokens carry it: in lower case, as the dispatcher
    /// keys it, however a wrapper spells it.
    nonisolated static func agentKey(_ agent: String) -> String {
        agent.lowercased()
    }
}
