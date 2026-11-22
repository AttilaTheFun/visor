import Foundation

public struct GitHubRequest: Sendable, Equatable {
    public var method: String
    /// `/repos/…` under https://api.github.com, or a whole URL there (a
    /// redirect's).
    public var path: String
    public var query: [String: String]
    public var body: JSON?
    public var accept: String

    public init(method: String, path: String, query: [String: String] = [:], body: JSON? = nil, accept: String = "application/vnd.github+json") {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
    }
}
