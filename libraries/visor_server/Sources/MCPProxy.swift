// The MCP servers this server passes on to its sessions' agents
// (MCPEndpoint): a session's tools from each it has, named
// `<endpoint>__<tool>`, and its calls passed on with its own headers. Visor's
// MCP script (VisorMCPScript) asks for both over the agent's WebSocket; an
// agent never sees an endpoint's address or its secret headers.

import Foundation
import VisorProtocol

@MainActor
final class MCPProxy {
    /// Each session's conversation with each endpoint, by endpoint and session.
    private var connections: [String: MCPConnection] = [:]
    /// The most pages of tools asked of one endpoint.
    static let pages = 10
    /// How long a call may run (a test suite, a lease that waits).
    static let callTimeout: Double = 900

    /// The tools of the endpoints a session has, each renamed under its
    /// endpoint; one that doesn't answer gives none.
    func tools(of endpoints: [MCPEndpoint], session: String, title: String, secrets: any SecretStore) async -> [JSONValue] {
        var listed: [JSONValue] = []
        for endpoint in endpoints {
            let connection = connection(endpoint, session: session, title: title, secrets: secrets)
            var cursor: String?
            for _ in 0..<Self.pages {
                let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
                guard let page = try? await connection.request("tools/list", params) else { break }
                for tool in page["tools"].array ?? [] {
                    guard var fields = tool.object, let name = tool["name"].string else { continue }
                    fields["name"] = .string(endpoint.name + "__" + name)
                    listed.append(.object(fields))
                }
                cursor = page["nextCursor"].string
                if cursor == nil { break }
            }
        }
        return listed
    }

    /// A call of `tool` (`<endpoint>__<tool>`) passed on to its endpoint,
    /// answered with the endpoint's result as it gave it.
    func call(_ tool: String, arguments: JSONValue, endpoints: [MCPEndpoint], session: String, title: String,
              secrets: any SecretStore) async throws -> JSONValue {
        guard let split = tool.range(of: "__") else { throw MCPProxyError.noEndpoint(tool) }
        let name = String(tool[..<split.lowerBound])
        guard let endpoint = endpoints.first(where: { $0.name == name }) else { throw MCPProxyError.noEndpoint(name) }
        let connection = connection(endpoint, session: session, title: title, secrets: secrets)
        return try await connection.request("tools/call", .object(["name": .string(String(tool[split.upperBound...])), "arguments": arguments]),
                                            timeout: Self.callTimeout)
    }

    /// A session's connection to an endpoint, its headers as they are now;
    /// a new one when the endpoint moved.
    private func connection(_ endpoint: MCPEndpoint, session: String, title: String, secrets: any SecretStore) -> MCPConnection {
        let key = endpoint.name + "\u{0}" + session
        let headers = endpoint.filledHeaders(session: session, title: title, secrets: secrets)
        if let known = connections[key], known.url == endpoint.url {
            known.headers = headers
            return known
        }
        let made = MCPConnection(url: endpoint.url, headers: headers)
        connections[key] = made
        return made
    }

    /// A proxied tool as a session's row shows a call of it: "gh: pr_create"
    /// for Claude's `mcp__visor__gh__pr_create` or Codex's `gh__pr_create`;
    /// nil for any other tool.
    nonisolated static func shownName(_ tool: String) -> String? {
        let name = tool.hasPrefix("mcp__visor__") ? String(tool.dropFirst("mcp__visor__".count)) : tool
        guard let split = name.range(of: "__"), split.lowerBound > name.startIndex else { return nil }
        return name[..<split.lowerBound] + ": " + name[split.upperBound...]
    }

    /// A session's connections let go: it ended.
    func forget(session: String) {
        connections = connections.filter { !$0.key.hasSuffix("\u{0}" + session) }
    }
}
