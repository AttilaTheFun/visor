import Foundation

/// How requests reach GitHub: URLSession here, a fake in the tests.
public protocol GitHubTransport: Sendable {
    /// One request with the token, redirects not followed.
    func send(_ request: GitHubRequest, token: String) async throws -> GitHubResponse
    /// A redirect's target (a log's, an artifact's: signed URLs off
    /// GitHub's API), fetched with no credential.
    func fetch(_ url: String) async throws -> GitHubResponse
    /// The same, written to `file` (an artifact's zip).
    func download(_ url: String, to file: String) async throws
}
