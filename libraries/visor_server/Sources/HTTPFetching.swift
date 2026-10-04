/// Requests from the server to elsewhere: another computer's server it is
/// linked to, and APNs. The system's own HTTP client, which speaks TLS and
/// the HTTP versions those need.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer
}
