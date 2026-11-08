import Foundation

/// The Runner's side for clients (docs/runner-accounts.md, step 2): signing
/// in, signing out, and the servers a session may reach. Nothing is proxied
/// to a server yet. Every answer is JSON.
///
/// | Request | Answer |
/// |---|---|
/// | `GET /runner/v1/sign-in` | `{"providers": [{"kind"}]}`, unauthenticated |
/// | `POST /runner/v1/sign-in` | `{"kind"?, …proof}` → `{"token", "expires", "account"}`, or 401 |
/// | `POST /runner/v1/sign-out` | ends the bearer's session: 200 |
/// | `GET /runner/v1/servers` | `{"servers": [{"id", "name", "kind"}]}` for the bearer's session, or 401 |
public struct RunnerAPI: Sendable {
    public struct Answer: Equatable, Sendable {
        public var status: Int
        public var body: Data
    }

    private let auths: [any RunnerAuth]
    private let sessions: RunnerSessions
    private let servers: @Sendable () -> [RunnerServerInfo]

    /// `auths`: the sign-ins offered, the first the default; `servers`, as
    /// the Runner's configuration has them now.
    public init(auths: [any RunnerAuth], sessions: RunnerSessions, servers: @escaping @Sendable () -> [RunnerServerInfo]) {
        self.auths = auths
        self.sessions = sessions
        self.servers = servers
    }

    /// The answer to a request: its method, its path (a query is ignored),
    /// its `Authorization` header and its body.
    public func answer(method: String, path: String, authorization: String?, body: Data, now: Date = Date()) -> Answer {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        switch (method, route) {
        case ("GET", "/runner/v1/sign-in"):
            return Self.json(200, ["providers": auths.map { ["kind": $0.kind] }])
        case ("POST", "/runner/v1/sign-in"):
            return signIn(body, now: now)
        case ("POST", "/runner/v1/sign-out"):
            if let token = Self.bearer(authorization) { sessions.end(token, now: now) }
            return Self.json(200, [:])
        case ("GET", "/runner/v1/servers"):
            guard let token = Self.bearer(authorization), sessions.user(for: token, now: now) != nil else { return Self.refused }
            return Self.json(200, ["servers": servers().map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] }])
        default:
            return Self.json(404, ["error": "No such request"])
        }
    }

    /// Whether this is a request of the Runner's side for clients.
    public static func handles(_ path: String) -> Bool { path.hasPrefix("/runner/v1/") }

    private func signIn(_ body: Data, now: Date) -> Answer {
        guard let proof = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Self.json(400, ["error": "A sign-in is JSON"])
        }
        let kind = proof["kind"] as? String
        guard let auth = kind.map({ kind in auths.first { $0.kind == kind } }) ?? auths.first else {
            return Self.json(400, ["error": "No sign-in of that kind here"])
        }
        guard let user = auth.user(for: proof) else { return Self.refused }
        let session = sessions.begin(user: user, now: now)
        return Self.json(200, ["token": session.token, "expires": session.expires.timeIntervalSince1970, "account": user])
    }

    /// A sign-in that proved nothing, or a request with no live session:
    /// the same words for both, so neither tells which part was wrong.
    static let refused = json(401, ["error": "Not signed in"])

    static func bearer(_ authorization: String?) -> String? {
        guard let authorization, authorization.lowercased().hasPrefix("bearer ") else { return nil }
        let token = authorization.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func json(_ status: Int, _ object: [String: Any]) -> Answer {
        Answer(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
}
