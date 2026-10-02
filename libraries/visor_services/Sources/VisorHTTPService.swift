/// One HTTPS request (the REST side of the protocol). Returns the body for
/// a 2xx status; throws with the status and body otherwise.
public protocol VisorHTTPService: Sendable {
    func request(method: String, url: String, body: String, authorization: String) async throws -> String
    /// The HTTP status behind an error `request` threw, when it was one
    /// (a 401 is how a computer asks for a password).
    func status(of error: Error) -> Int?
}

public extension VisorHTTPService {
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
