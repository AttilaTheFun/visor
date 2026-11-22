import Foundation

/// gh_mcp's answer to a call: its status, its headers and its body, as its
/// own listener sent them.
public struct MCPHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSON, status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: value.data())
    }

    public static func text(_ text: String, status: Int) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data((text + "\n").utf8))
    }
}
