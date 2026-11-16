// A wrapped agent's MCP server, "visor" (agent_protocol's WrapperMessage.mcp,
// relayed by its wrapper from Claude's `agent-wrapper mcp`): Visor's own
// (VisorMCPBridge's MCPBridge, as a session here runs it), answering for
// the session the wrapper's token says it is. One bridge for each of the
// wrapper's MCP connections (`client`), for as long as the wrapper's
// connection lasts. Its tools are only Visor's own (the other sessions,
// their messages, its inbox): never the MCP servers this computer passes
// on to its native sessions (gh, shireworks, …), whatever the session's
// switches say (Logan, 2026-11-16: a container's agent gets Visor's MCP
// from here and Shireworks' from its container). Not `approve` either,
// which the wrapper offers and turns into WrapperMessage.approval
// (DrivenProcess).

import AgentProtocol
import Foundation
import VisorMCPBridge
import VisorProtocol
import VisorServer

actor DrivenMCP {
    private let session: String
    private let server: VisorServer
    private let send: @Sendable (AgentProtocol_V1_DriverMessage) -> Void
    private var bridges: [String: (bridge: MCPBridge, output: DrivenMCPOutput)] = [:]

    /// For the driven session `session`; what it answers goes to `send`
    /// (down the wrapper's connection).
    init(session: String, server: VisorServer, send: @escaping @Sendable (AgentProtocol_V1_DriverMessage) -> Void) {
        self.session = session
        self.server = server
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
        let (bridge, output) = connection(request.client)
        // Its answer, whenever the bridge gives it, goes back under the
        // wrapper's id for the request.
        if !request.id.isEmpty, !message["id"].isNull { output.expect(message["id"], as: request.id) }
        await bridge.handle(request.json)
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
        // No `approve` (the wrapper's own), no passed-on servers, and what
        // a session on this computer is told at `initialize`.
        let bridge = MCPBridge(link: DrivenMCPLink(session: session, server: server), output: output, approvals: false, contained: false,
                               passesOn: false)
        bridges[client] = (bridge, output)
        return (bridge, output)
    }
}
