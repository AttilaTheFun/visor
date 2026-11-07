import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The GitHub proxy's tokens from Keymaster (Keymaster's docs/PROTOCOL.md):
/// the proxy is a client of its own (`<Mac>-github-proxy`), its key in the
/// Runner's secrets alone, and asks `POST /v1/github/token` naming the
/// session (`Keymaster-Session`) and its repository (`Keymaster-Repository`),
/// for the agents' App. Each token is kept for the session and repository
/// until five minutes before it expires, and at most ten minutes. A 401 from
/// Keymaster (a revoked client) is not asked again: the request fails, saying
/// so.
actor KeymasterTokens: GitHubTokenSource {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let url: URL
    private let key: @Sendable () -> String?
    private let app: String
    private var kept: [String: (token: String, until: Date)] = [:]

    /// `url`: Keymaster's, `http://<its Mac>:7450`. `key`: the proxy's client
    /// key, read when it is needed. `app`: the GitHub App agents act as.
    init(url: URL, app: String, key: @escaping @Sendable () -> String?) {
        self.url = url
        self.app = app
        self.key = key
    }

    func token(session: String, repository: String) async throws -> String {
        let name = session + " " + repository.lowercased()
        if let held = kept[name], held.until > Date() { return held.token }
        guard let key = key(), !key.isEmpty else { throw Failure(description: "the GitHub proxy has no Keymaster key (github-proxy keymaster)") }
        var request = URLRequest(url: url.appendingPathComponent("v1/github/token"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "Keymaster-Session")
        request.setValue(repository, forHTTPHeaderField: "Keymaster-Repository")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["app": app, "repositories": [repository]])
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 201 || status == 200, let token = answer["token"] as? String, !token.isEmpty else {
            let why = answer["error"] as? String ?? "status \(status)"
            throw Failure(description: status == 401 ? "Keymaster no longer takes the GitHub proxy's key: \(why)" : "Keymaster gave no token: \(why)")
        }
        var until = Date().addingTimeInterval(600)
        if let expires = (answer["expires_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            until = min(until, expires.addingTimeInterval(-300))
        }
        kept[name] = (token, until)
        return token
    }

    func forget(session: String, repository: String) {
        kept[session + " " + repository.lowercased()] = nil
    }
}
