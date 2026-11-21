import Foundation
import VisorProtocol

/// Visor's server over its WebSocket, a connection for each call, as the
/// agent's session: an `agent` request answered by its `agent_result`, an
/// `approval_request` by its `approval_result`. Closing the socket of an
/// `approve` the person hasn't answered withdraws the prompt.
///
/// Nothing is held between calls, so a server that restarted, was updated
/// in place or re-minted the token is simply reached again: each call
/// connects afresh (to the port, which an update keeps) with the token
/// file as it is then. A server that isn't answering yet (one restarting)
/// is dialled again a few times, waiting longer each time (`redials`),
/// before the call says Visor is not reachable. Only the connection is
/// tried again, never a request once sent: a message isn't sent twice.
struct MCPWebSocketLink: MCPServerLink {
    /// `ws://host:port`: this computer's server, or the computer a
    /// container's agent runs on.
    let url: String
    /// The session's agent token as the agent was started with it
    /// (VISOR_TOKEN): taken only when there is no token file, or it can't
    /// be read (a server too old to write one).
    let token: String
    /// The session the agent is (VISOR_SESSION).
    let session: String
    /// Where the server keeps the session's token fresh (VISOR_TOKEN_FILE):
    /// read on each call, since it is re-minted hourly.
    var tokenFile: String? = nil
    /// The waits before each dial after the first fails: 0.25 s doubling,
    /// about 8 s in all, the time a server agent takes to come back.
    var redials: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]

    /// The token to show now: the file's, else VISOR_TOKEN.
    var currentToken: String {
        guard let tokenFile, !tokenFile.isEmpty, let data = FileManager.default.contents(atPath: tokenFile) else { return token }
        let read = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return read.isEmpty ? token : read
    }

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        let unreachable = MCPReply(ok: false, text: "Visor is not reachable.")
        guard let socket = await open() else { return unreachable }
        defer { socket.shut() }
        let id = Self.requestID()
        var message = fields
        message["type"] = .string("agent")
        message["token"] = .string(currentToken)
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
        guard let socket = await open() else { return .no }
        defer { socket.shut() }
        guard asking.whenCancelled({ socket.shut() }) else { return MCPAnswer(allow: false, answers: nil, reason: asking.reason) }
        let id = Self.requestID()
        var message = request
        message["type"] = .string("approval_request")
        message["token"] = .string(currentToken)
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

    /// A WebSocket to the server, dialled again after each wait in
    /// `redials` while it doesn't answer; nil once they are spent, or the
    /// call is given up on.
    private func open() async -> MCPWebSocket? {
        if let socket = await MCPWebSocket.open(url) { return socket }
        for wait in redials {
            try? await Task.sleep(for: wait)
            if Task.isCancelled { return nil }
            if let socket = await MCPWebSocket.open(url) { return socket }
        }
        return nil
    }

    /// An id for one request: the time and six random letters or digits.
    static func requestID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<6).map { _ in letters.randomElement() ?? "a" })
        return "\(Int(Date().timeIntervalSince1970 * 1000))-\(suffix)"
    }
}
