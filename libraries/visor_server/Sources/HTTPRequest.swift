public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: String
    /// Whether the connection it came on is one only this user could
    /// open (the socket file an SSH client reaches): then it is let in
    /// without a bearer.
    public var trusted = false

    /// The bearer token; "" for a bare `Bearer` (no password).
    public var authorization: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "bearer" else { return nil }
        return parts.count == 2 ? String(parts[1]) : ""
    }
}
