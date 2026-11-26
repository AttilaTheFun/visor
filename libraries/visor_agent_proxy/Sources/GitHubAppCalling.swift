import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How the GitHub App's own calls reach GitHub's API: its installations
/// listed, an installation's token minted and the App itself read, with its
/// JWT; its bot user read, with an installation's token (GitHubAppTokens).
/// GitHub's (GitHubAppAPI); a test's stand-in.
protocol GitHubAppCalling: Sendable {
    /// `method` `https://api.github.com<path>` (its query included) with
    /// `jwt`, and `body` as JSON where there's one: GitHub's status and
    /// body. Throws when GitHub didn't answer.
    func call(_ method: String, _ path: String, jwt: String, body: Data?) async throws -> (status: Int, body: Data)

    /// `GET https://api.github.com<path>` with an installation's `token`
    /// (not anonymously: anonymous reads share the containers' sixty an
    /// hour). Throws when GitHub didn't answer.
    func read(_ path: String, token: String) async throws -> (status: Int, body: Data)
}

/// GitHub's API, as the App.
struct GitHubAppAPI: GitHubAppCalling {
    var base = "https://api.github.com"

    func call(_ method: String, _ path: String, jwt: String, body: Data?) async throws -> (status: Int, body: Data) {
        try await send(method, path, bearer: jwt, body: body)
    }

    func read(_ path: String, token: String) async throws -> (status: Int, body: Data) {
        try await send("GET", path, bearer: token, body: nil)
    }

    private func send(_ method: String, _ path: String, bearer: String, body: Data?) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("visor-agent-proxy", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
