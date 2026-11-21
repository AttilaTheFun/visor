import Foundation
import Synchronization
@testable import VisorGHMCP

/// GitHub answered from a table of paths; every request recorded.
final class FakeTransport: GitHubTransport, Sendable {
    private let heard = Mutex<[GitHubRequest]>([])
    private let shown = Mutex<[String]>([])
    let answers: [String: (Int, JSON)]

    init(_ answers: [String: (Int, JSON)] = [:]) {
        self.answers = answers
    }

    var requests: [GitHubRequest] { heard.withLock { $0 } }
    /// The token each request carried, in turn.
    var tokens: [String] { shown.withLock { $0 } }

    func send(_ request: GitHubRequest, token: String) async throws -> GitHubResponse {
        heard.withLock { $0.append(request) }
        shown.withLock { $0.append(token) }
        let (status, body) = answers["\(request.method) \(request.path)"] ?? (404, ["message": "Not Found"])
        return GitHubResponse(status: status, headers: ["content-type": "application/json"], body: body.data())
    }

    func fetch(_ url: String) async throws -> GitHubResponse { GitHubResponse(status: 404) }
    func download(_ url: String, to file: String) async throws { throw ToolError.failed("no downloads in tests") }
}
