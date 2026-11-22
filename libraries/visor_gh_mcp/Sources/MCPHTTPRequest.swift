import Foundation

/// A call as gh_mcp's server reads it: its method, its headers and its body
/// (agent-proxy has read it and checked the sessions' token; gh_mcp's own
/// HTTP listener and its keys stayed behind).
public struct MCPHTTPRequest: Sendable, Equatable {
    public var method: String
    /// Field names lowercased, `_` read as `-` (so `CLIENT_ID` is
    /// `client-id`, and a proxy that rewrites one as the other changes
    /// nothing).
    public var headers: [String: String]
    public var body: Data

    public init(method: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.headers = Dictionary(headers.map { (Self.fieldName($0.key), $0.value) }, uniquingKeysWith: { first, second in first + ", " + second })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[Self.fieldName(name)] }

    static func fieldName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
