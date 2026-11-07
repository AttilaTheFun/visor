import Foundation

/// A request the GitHub proxy has opened, as GitHubGate sees it: before any
/// of it goes on to GitHub.
public struct GateRequest: Equatable, Sendable {
    public var method: String
    /// `github.com`, `api.github.com` or `uploads.github.com`.
    public var host: String
    /// The request target as sent: the path and its query.
    public var target: String
    /// The body, whole, for what the gate reads of it (a JSON write, a
    /// GraphQL document, LFS's batch); nil for none. A git push's pack is
    /// never here: its command list is checked on its own (`decidePush`).
    public var body: Data?

    public init(method: String, host: String, target: String, body: Data? = nil) {
        self.method = method
        self.host = host
        self.target = target
        self.body = body
    }

    /// The path, without the query.
    var path: String { target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }

    /// The query, if any (after the first `?`).
    var query: String? {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}
