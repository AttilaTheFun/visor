/// What a server's operation can fail with, beyond its own errors.
public enum AgentServerError: Error, Equatable, Sendable {
    /// The credentials are missing or refused: the user has to sign in
    /// (or type the password) before anything else is tried.
    case needsAuthentication
    /// The server has no such operation (linking, say).
    case unsupported
    /// The server answered with a message for the user.
    case message(String)
}
