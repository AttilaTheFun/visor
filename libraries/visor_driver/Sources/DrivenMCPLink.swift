// How a wrapped agent's MCP bridge (DrivenMCP) reaches the server: its
// asks of the other sessions answered here as its session's
// (VisorServer.answerDrivenAgent), with no socket and no token of the
// server's own (its driver knows the session by the agent's token). Its
// `approve` is never called (the bridge is made without it): the wrapper
// asks approvals as WrapperMessage.approval.

import VisorMCPBridge
import VisorProtocol
import VisorServer

struct DrivenMCPLink: MCPServerLink {
    let session: String
    let server: VisorServer

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        let reply = await server.answerDrivenAgent(session, fields: fields)
        return MCPReply(ok: reply.ok, text: reply.text)
    }

    func ask(_ request: [String: JSONValue], _ asking: MCPAsking) async -> MCPAnswer {
        .no
    }
}
