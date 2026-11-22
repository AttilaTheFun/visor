import Foundation

/// GitHub's REST API as one agent's app, its token from the cache.
public struct GitHub: Sendable {
    public let transport: any GitHubTransport
    public let tokens: TokenCache
    public let agent: String

    public init(transport: any GitHubTransport, tokens: TokenCache, agent: String) {
        self.transport = transport
        self.tokens = tokens
        self.agent = agent
    }

    /// The token gh_mcp acts with for `owner`'s repositories.
    public func token(for repo: RepoName) async throws -> String {
        try await tokens.token(agent: agent, owner: repo.owner)
    }

    /// One request; a 401 drops the token and tries once more with a new
    /// one, and a redirect within api.github.com (a renamed repository) is
    /// followed with the token.
    public func send(
        _ repo: RepoName, _ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
        accept: String = "application/vnd.github+json"
    ) async throws -> GitHubResponse {
        var request = GitHubRequest(method: method, path: path, query: query, body: body, accept: accept)
        var retried = false
        var redirects = 0
        while true {
            if let reason = Policy.refusal(request, repo: repo) { throw ToolError.refused(reason) }
            let token = try await tokens.token(agent: agent, owner: repo.owner)
            let response = try await transport.send(request, token: token)
            if response.status == 401 && !retried {
                retried = true
                await tokens.invalidate(agent: agent, owner: repo.owner, token: token)
                continue
            }
            if response.isRedirect, let location = response.location, location.hasPrefix("https://api.github.com/"),
               redirects < 3, method == "GET" {
                redirects += 1
                request = GitHubRequest(method: method, path: location, accept: accept)
                continue
            }
            return response
        }
    }

    /// A request whose answer is JSON; anything but a 2xx is a failure
    /// saying what GitHub said.
    public func json(_ repo: RepoName, _ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil) async throws -> JSON {
        let response = try await send(repo, method, path, query: query, body: body)
        guard response.isSuccess else { throw ToolError.failed(Self.describe(response, method: method, path: path)) }
        if response.body.isEmpty { return .null }
        do {
            return try JSON.parse(response.body)
        } catch {
            throw ToolError.failed("GitHub's answer to \(method) \(path) was not JSON")
        }
    }

    /// A redirect's target, fetched without the token (GitHub's logs and
    /// artifacts are signed URLs elsewhere).
    public func followed(_ response: GitHubResponse, what: String) async throws -> GitHubResponse {
        if response.isSuccess { return response }
        guard response.isRedirect, let location = response.location else {
            throw ToolError.failed(Self.describe(response, method: "GET", path: what))
        }
        let target = try await transport.fetch(location)
        guard target.isSuccess else { throw ToolError.failed("\(what): its storage answered \(target.status)") }
        return target
    }

    /// GitHub's error, one line: its status, its message and the errors'.
    public static func describe(_ response: GitHubResponse, method: String, path: String) -> String {
        var text = "GitHub answered \(response.status) to \(method) \(path)"
        if let json = try? JSON.parse(response.body) {
            if let message = json["message"]?.stringValue { text += ": \(message)" }
            let details = (json["errors"]?.arrayValue ?? []).compactMap { error -> String? in
                error["message"]?.stringValue ?? error["code"]?.stringValue.map { code in
                    [error["field"]?.stringValue, code].compactMap { $0 }.joined(separator: " ")
                }
            }
            if !details.isEmpty { text += " (\(details.joined(separator: "; ")))" }
        } else if !response.body.isEmpty {
            text += ": " + String(response.text.prefix(200))
        }
        return Redact.line(text, limit: 500)
    }
}
