// A wrapped agent's MCP server, "visor" (agent_protocol's WrapperMessage.mcp,
// relayed by its wrapper from Claude's `agent-wrapper mcp`): Visor's own
// (VisorMCPBridge's MCPBridge, as a session here runs it), answering for
// the session the wrapper's token says it is. One bridge for each of the
// wrapper's MCP connections (`client`), for as long as the wrapper's
// connection lasts. For an agent in a container (JobQueue.runsInContainer),
// its tools are only Visor's own (the other sessions, their messages, its
// inbox): never the MCP servers this computer passes on to its native
// sessions (gh, shireworks, …), whatever the session's switches say (Logan,
// 2026-11-16: a container's agent gets Visor's MCP from here and
// Shireworks' from its container). An agent on Visor's own native runner
// runs on this computer, and gets them as any native session does. Not
// `approve` either, which the wrapper offers and turns into
// WrapperMessage.approval (DrivenProcess).
//
// The passed-on servers reach a container's agent another way (0.72.1;
// docs/containers.md, "MCP in the container"): from agent-proxy's
// pass-through, through the relay, each call showing a token of the
// agent's own. Its harness asks for one here, over this same stream
// (`visor/passThroughHeaders`, which `visor-agent-host mcp-headers`, the
// container Claude's headersHelper, sends through the wrapper's MCP socket):
// answered with the headers to show (`X-Visor-Proxy`, a fresh token for MCP
// alone), never by the bridge. An agent that isn't the container runner's
// is answered that it has none.

import AgentProtocol
import Foundation
import VisorMCPBridge
import VisorProtocol
import VisorServer

actor DrivenMCP {
    private let session: String
    private let server: VisorServer
    private let send: @Sendable (AgentProtocol_V1_DriverMessage) -> Void
    /// Whether the computer's passed-on MCP servers are offered: not to an
    /// agent in a container.
    private let passesOn: Bool
    /// A fresh token for the agent's calls to agent-proxy's MCP pass-through
    /// (the container runner's agents'); none: it has none.
    private let passThroughToken: (@Sendable () async -> String?)?
    private var bridges: [String: (bridge: MCPBridge, output: DrivenMCPOutput)] = [:]

    /// The method a harness asks for the pass-through's headers by.
    static let passThroughHeaders = "visor/passThroughHeaders"
    /// The header agent-proxy's pass-through takes a token in (its
    /// NativeMCPProxy.tokenHeader).
    static let passThroughTokenHeader = "X-Visor-Proxy"

    /// For the driven session `session`; what it answers goes to `send`
    /// (down the wrapper's connection). `passThroughToken`: a fresh token
    /// for the agent's calls to agent-proxy's MCP pass-through, if it has
    /// them.
    init(session: String, server: VisorServer, passesOn: Bool, passThroughToken: (@Sendable () async -> String?)? = nil,
         send: @escaping @Sendable (AgentProtocol_V1_DriverMessage) -> Void) {
        self.session = session
        self.server = server
        self.passesOn = passesOn
        self.passThroughToken = passThroughToken
        self.send = send
    }

    /// One JSON-RPC message from the agent's MCP client `request.client`:
    /// a request (an `id` of the wrapper's) to answer, or a notification.
    func take(_ request: AgentProtocol_V1_McpRequest) async {
        guard let message = parseJSON(request.json), message.object != nil else {
            // Unreadable: said so, if it waits for an answer.
            guard !request.id.isEmpty else { return }
            let error = JSONValue.object(["jsonrpc": .string("2.0"), "id": .null,
                                          "error": .object(["code": .number(-32700), "message": .string("The request isn't a JSON object.")])])
            send(.with { $0.mcp = .with { $0.id = request.id; $0.json = error.encoded(); $0.client = request.client } })
            return
        }
        if message["method"].string == Self.passThroughHeaders {
            guard !request.id.isEmpty else { return }
            let answer = await passThroughAnswer(id: message["id"])
            send(.with { $0.mcp = .with { $0.id = request.id; $0.json = answer.encoded(); $0.client = request.client } })
            return
        }
        let (bridge, output) = connection(request.client)
        // Its answer, whenever the bridge gives it, goes back under the
        // wrapper's id for the request.
        if !request.id.isEmpty, !message["id"].isNull { output.expect(message["id"], as: request.id) }
        await bridge.handle(request.json)
    }

    /// The answer to `visor/passThroughHeaders` (JSON-RPC id `id`): the
    /// headers the pass-through takes, with a fresh token; or an error, for
    /// an agent that has no token for it.
    private func passThroughAnswer(id: JSONValue) async -> JSONValue {
        guard let passThroughToken, let token = await passThroughToken() else {
            return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                "code": .number(-32601),
                "message": .string("This agent has no token for agent-proxy's MCP pass-through: only an agent in the Sessions container has one."),
            ])])
        }
        return .object(["jsonrpc": .string("2.0"), "id": id,
                        "result": .object(["headers": .object([Self.passThroughTokenHeader: .string(token)])])])
    }

    /// The wrapper's connection ended: each bridge's own work stopped.
    func close() async {
        let open = bridges.values.map { $0.bridge }
        bridges = [:]
        for bridge in open { await bridge.close() }
    }

    private func connection(_ client: String) -> (MCPBridge, DrivenMCPOutput) {
        if let open = bridges[client] { return open }
        let output = DrivenMCPOutput(client: client, deliver: send)
        // No `approve` (the wrapper's own), the passed-on servers only off
        // containers, and what a session on this computer is told at
        // `initialize`.
        let bridge = MCPBridge(link: DrivenMCPLink(session: session, server: server), output: output, approvals: false, contained: false,
                               passesOn: passesOn)
        bridges[client] = (bridge, output)
        return (bridge, output)
    }
}
