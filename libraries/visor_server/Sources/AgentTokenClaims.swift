// What an agent's token says (its JWT's payload): who minted it, whom it is
// for, the session it acts as, the runner's agent it is (for one), what it
// may do, and when it was minted and ends.

/// An agent's token's claims, as minted and as read back.
package struct AgentTokenClaims: Codable, Equatable, Sendable {
    /// The server that minted it (its id).
    package var iss: String
    /// Whom it is for (AgentTokenAudience's raw value).
    package var aud: String
    /// The session it acts as, and only as.
    package var sub: String
    /// A runner's agent's id (agent_protocol's AgentID.uuid): the one its
    /// wrapper's hello must name. Absent from a session's token.
    package var agent: String?
    /// What it may do (AgentTokenScope's raw values).
    package var scope: [String]
    /// When it was minted, and when it ends: seconds since 1970.
    package var iat: Int
    package var exp: Int
    /// Its own id.
    package var jti: String

    package init(iss: String, aud: String, sub: String, agent: String? = nil, scope: [String], iat: Int, exp: Int, jti: String) {
        self.iss = iss
        self.aud = aud
        self.sub = sub
        self.agent = agent
        self.scope = scope
        self.iat = iat
        self.exp = exp
        self.jti = jti
    }

    /// Whether it may be used for `scope`.
    package func allows(_ scope: AgentTokenScope) -> Bool {
        self.scope.contains(scope.rawValue)
    }
}
