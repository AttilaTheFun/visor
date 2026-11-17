// Why an agent's token was refused: said to the caller (an agent, a
// wrapper), and to the log. Never the token.

/// Why a token isn't taken.
package enum AgentTokenRefusal: Error, Equatable, Sendable {
    /// Not a JWT this server could have made (its shape, its header).
    case malformed
    /// Signed with a key this server doesn't hold (rotated out, or never
    /// its own).
    case unknownKey
    /// Its signature isn't its key's.
    case badSignature
    /// Minted by another server.
    case wrongIssuer
    /// For another use (a session's token shown as a runner's agent's, or
    /// the other way round).
    case wrongAudience
    /// Past its `exp`.
    case expired
    /// Its session is gone, or not this one.
    case wrongSession
    /// Its session is archived.
    case archived
    /// A runner's agent's token shown for another agent.
    case wrongAgent
    /// It may not be used for this.
    case outOfScope

    /// What the caller is told.
    package var message: String {
        switch self {
        case .malformed: "That isn't a token this server minted."
        case .unknownKey: "That token was signed with a key this server no longer holds (its keys were rotated)."
        case .badSignature: "That token's signature is wrong."
        case .wrongIssuer: "That token is another server's."
        case .wrongAudience: "That token is for another use."
        case .expired: "That token has expired."
        case .wrongSession: "That token is another session's, or its session is gone."
        case .archived: "That token's session is archived."
        case .wrongAgent: "That token is another agent's."
        case .outOfScope: "That token may not be used for this."
        }
    }
}
