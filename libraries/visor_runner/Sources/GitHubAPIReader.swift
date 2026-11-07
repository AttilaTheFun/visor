import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The checks' reads of GitHub's API (GitHubReading), with one token: the
/// session's, for the repository the write is to.
struct GitHubAPIReader: GitHubReading {
    let token: String
    var base = URL(string: "https://api.github.com")!

    func get(_ path: String) async -> GitHubAnswer {
        guard let url = URL(string: base.absoluteString + path) else { return GitHubAnswer(status: 0, json: nil) }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return await send(request)
    }

    func graphQL(_ query: String, variables: [String: GateJSON]) async -> GitHubAnswer {
        var request = URLRequest(url: base.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables.mapValues(\.foundation)])
        return await send(request)
    }

    private func send(_ request: URLRequest) async -> GitHubAnswer {
        var request = request
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("visor-runner", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return GitHubAnswer(status: 0, json: nil) }
        return GitHubAnswer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, json: GateJSON.parse(data))
    }
}
