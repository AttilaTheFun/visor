import Foundation

/// What answers a container's `/mcp/<name>` (Shireworks had its own MCP here,
/// dropped in Visor; the container runner gives one). None: the relay
/// listener answers 404.
public protocol MCPAnswering: Sendable {
    /// Answers `request` (read whole: at most the relay listener's 64 KB)
    /// from `caller` on `stream` (the relay listener closes it after).
    func answerMCP(_ stream: Int32, _ request: HTTPRequest, caller: EgressProxy.Caller)
}
