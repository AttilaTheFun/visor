public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: String
    /// Whether the connection it came on is one only this user could
    /// open (the socket file an SSH client, or Visor.app, reaches): then
    /// it is let in without a bearer, while SSH clients are or for the app
    /// (VisorServer.trusts).
    public var trusted = false
    /// The address it came from, where the system says (never on the
    /// socket file): what wrong passwords are counted by (PasswordThrottle).
    public var peer: String?

    /// The bearer token; "" for a bare `Bearer` (no password).
    public var authorization: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "bearer" else { return nil }
        return parts.count == 2 ? String(parts[1]) : ""
    }
}
