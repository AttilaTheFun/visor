import VisorProtocol

/// Where the MCP server's messages to the agent go: one JSON message a
/// line (MCPStandardOutput); a test's own.
protocol MCPOutput: Sendable {
    func send(_ message: JSONValue)
}
