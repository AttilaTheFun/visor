/// One HTTPS request (the REST side of the protocol). Returns the body for
/// a 2xx status; throws with the status and body otherwise.
public protocol VisorHTTPService: Sendable {
    /// With a bearer token (`Authorization: Bearer <authorization>`).
    func request(method: String, url: String, body: String, authorization: String) async throws -> String
    /// With whatever headers the authenticator gives. A host that has
    /// only the bearer form sends the bearer out of these.
    func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String
    /// The HTTP status behind an error `request` threw, when it was one
    /// (a 401 is how a computer asks for a password).
    func status(of error: Error) -> Int?
    /// Lets go of every connection it holds, and whatever is in flight on
    /// them, so the next request makes its own: asked when the app comes
    /// back from the background, where the connections it left are dead
    /// without saying so.
    func reset()
}

public extension VisorHTTPService {
    func reset() {}
    func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        let bearer = headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
        let token = bearer.lowercased().hasPrefix("bearer ") ? String(bearer.dropFirst(7)) : bearer
        return try await request(method: method, url: url, body: body, authorization: token)
    }
    /// A host whose errors read "HTTP <status>: …" needs nothing more.
    func status(of error: Error) -> Int? {
        // The standard library alone: this builds for the browser, whose
        // Foundation has no `range(of:)`.
        let text = Array("\(error)")
        let marker = Array("HTTP ")
        guard text.count >= marker.count else { return nil }
        for start in 0...(text.count - marker.count) where Array(text[start..<start + marker.count]) == marker {
            return Int(String(text[(start + marker.count)...].prefix { $0.isNumber }))
        }
        return nil
    }
}
