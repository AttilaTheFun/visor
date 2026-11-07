import CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The GitHub proxy's token (docs/github-proxy.md): one for every agent,
/// which they never see, from the agents' GitHub App (logan-shire-agent) whose
/// private key the Runner alone holds (Logan, 7 Nov 2026). The Runner signs a
/// short JWT with the key (RS256) and asks GitHub for the App's installation
/// token (an hour), keeps it in memory, and asks again five minutes before it
/// expires, or at once when GitHub turns it down. Agents' pull requests stay
/// the App's, which the owner reviews.
actor GitHubAppTokens: GitHubTokenSource {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// GitHub's answer to a request: its body and status.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    private let appID: String
    private let installation: String
    private let key: @Sendable () -> String?
    private let api: URL
    private let fetch: Fetch
    private var held: (token: String, until: Date)?

    /// `key`: the App's private key (PEM), read from the Runner's secrets
    /// when a token is needed.
    init(appID: String, installation: String, key: @escaping @Sendable () -> String?,
         api: URL = URL(string: "https://api.github.com")!,
         fetch: @escaping Fetch = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
         }) {
        self.appID = appID
        self.installation = installation
        self.key = key
        self.api = api
        self.fetch = fetch
    }

    /// The one token, whichever session and repository: the gate decides what
    /// each request may do with it.
    func token(session: String, repository: String) async throws -> String {
        if let held, held.until > Date() { return held.token }
        guard let pem = key(), !pem.isEmpty else { throw Failure(description: "the GitHub proxy has no App key (github-proxy app)") }
        let jwt = try Self.jwt(appID: appID, pem: pem, now: Date())
        var request = URLRequest(url: api.appendingPathComponent("app/installations/\(installation)/access_tokens"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("visor-runner", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, status) = try await fetch(request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 201, let token = answer["token"] as? String, !token.isEmpty else {
            throw Failure(description: "GitHub gave the App no token (\(status)): \(answer["message"] as? String ?? "")")
        }
        var until = Date().addingTimeInterval(55 * 60)
        if let expires = (answer["expires_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            until = min(until, expires.addingTimeInterval(-300))
        }
        held = (token, until)
        return token
    }

    func forget(session: String, repository: String) {
        held = nil
    }

    /// The App's JWT: issued a minute back (for clocks apart), good for nine
    /// minutes, signed RS256 with its key.
    static func jwt(appID: String, pem: String, now: Date) throws -> String {
        let key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        let issued = Int(now.timeIntervalSince1970) - 60
        let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let claims = base64URL(Data("{\"iat\":\(issued),\"exp\":\(issued + 600),\"iss\":\"\(appID)\"}".utf8))
        let signed = header + "." + claims
        let signature = try key.signature(for: Data(signed.utf8), padding: .insecurePKCS1v1_5)
        return signed + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
