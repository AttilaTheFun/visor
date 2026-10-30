/// What went wrong passing a call on to a proxied MCP server, as the agent
/// is told it.
enum MCPProxyError: Error, Equatable, CustomStringConvertible {
    /// The server can't be reached.
    case unreachable(String)
    /// It answered with an HTTP status other than success.
    case http(Int, String)
    /// It answered with something that isn't its answer.
    case unreadable
    /// It answered the request with a JSON-RPC error.
    case rpc(String)
    /// It no longer knows the session it gave (it restarted): begun again.
    case sessionGone
    /// No endpoint, or none this session has, by that name.
    case noEndpoint(String)

    var description: String {
        switch self {
        case .unreachable(let why): "The MCP server can't be reached: \(why)"
        case .http(let status, let body): "The MCP server answered \(status)" + (body.isEmpty ? "." : ": \(body)")
        case .unreadable: "The MCP server's answer couldn't be read."
        case .rpc(let message): message
        case .sessionGone: "The MCP server forgot this session."
        case .noEndpoint(let name): "No MCP server \(name) for this session."
        }
    }
}
