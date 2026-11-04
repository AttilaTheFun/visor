import VisorProtocol

/// How an agent's MCP server reaches Visor's server: a call about the
/// other sessions (the fields of an `agent` request), and an `approve` the
/// person answers. A WebSocket each (MCPWebSocketLink); a test's own.
protocol MCPServerLink: Sendable {
    func call(_ fields: [String: JSONValue]) async -> MCPReply
    func ask(_ request: [String: JSONValue], _ asking: MCPAsking) async -> MCPAnswer
}
