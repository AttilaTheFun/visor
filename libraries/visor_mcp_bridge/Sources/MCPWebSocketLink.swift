import Foundation
import VisorProtocol

/// Visor's server over its WebSocket, a connection for each call, as the
/// agent's session: an `agent` request answered by its `agent_result`, an
/// `approval_request` by its `approval_result`. Closing the socket of an
/// `approve` the person hasn't answered withdraws the prompt.
struct MCPWebSocketLink: MCPServerLink {
    /// `ws://host:port`: this computer's server, or the computer a
    /// container's agent runs on.
    let url: String
    /// The server's agent-side secret (VISOR_TOKEN).
    let token: String
    /// The session the agent is (VISOR_SESSION).
    let session: String

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        let unreachable = MCPReply(ok: false, text: "Visor is not reachable.")
        guard let socket = await MCPWebSocket.open(url) else { return unreachable }
        defer { socket.shut() }
        let id = Self.requestID()
        var message = fields
        message["type"] = .string("agent")
        message["token"] = .string(token)
        message["client"] = .string(session)
        message["id"] = .string(id)
        guard socket.send(JSONValue.object(message).encoded()) else { return unreachable }
        for await text in socket.messages {
            guard let event = parseJSON(text), event["type"].string == "agent_result", event["id"].string == id else { continue }
            if let error = event["error"].string, !error.isEmpty { return MCPReply(ok: false, text: error) }
            return MCPReply(ok: true, text: event["text"].string ?? "")
        }
        return MCPReply(ok: false, text: "Visor closed the connection.")
    }

    func ask(_ request: [String: JSONValue], _ asking: MCPAsking) async -> MCPAnswer {
        guard let socket = await MCPWebSocket.open(url) else { return .no }
        defer { socket.shut() }
        guard asking.whenCancelled({ socket.shut() }) else { return MCPAnswer(allow: false, answers: nil, reason: asking.reason) }
        let id = Self.requestID()
        var message = request
        message["type"] = .string("approval_request")
        message["token"] = .string(token)
        message["session"] = .string(session)
        message["id"] = .string(id)
        guard socket.send(JSONValue.object(message).encoded()) else { return .no }
        for await text in socket.messages {
            guard let event = parseJSON(text) else { continue }
            if event["type"].string == "approval_result", event["id"].string == id {
                // The server says the person's yes as `busy`.
                return MCPAnswer(allow: event["busy"].bool == true, answers: event["answers"].isNull ? nil : event["answers"], reason: nil)
            }
            if event["type"].string == "error" { return .no }
        }
        // Closed: by the server, or by giving up on the call.
        return MCPAnswer(allow: false, answers: nil, reason: asking.reason)
    }

    /// An id for one request: the time and six random letters or digits.
    static func requestID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<6).map { _ in letters.randomElement() ?? "a" })
        return "\(Int(Date().timeIntervalSince1970 * 1000))-\(suffix)"
    }
}
