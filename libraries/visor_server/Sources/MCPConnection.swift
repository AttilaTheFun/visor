// One session's conversation with one proxied MCP server, over Streamable
// HTTP: each JSON-RPC message POSTed to its address and answered as JSON or
// as a short SSE stream, after `initialize`; the session id it gives
// carried on every request after, and asked for again if it forgets it.

import Foundation
import VisorProtocol

@MainActor
final class MCPConnection {
    static let protocolVersion = "2025-06-18"
    let url: String
    /// The session's headers, filled in (MCPEndpoint.filledHeaders).
    var headers: [String: String]
    private var sessionID: String?
    private var opening: Task<Void, Error>?
    private var nextID = 1

    init(url: String, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    /// A request's result, initializing first if need be; begun again once
    /// if the server has forgotten the session.
    func request(_ method: String, _ params: JSONValue, timeout: Double = 60) async throws -> JSONValue {
        try await open()
        do {
            return try await exchange(method, params, timeout: timeout)
        } catch MCPProxyError.sessionGone {
            opening = nil
            sessionID = nil
            try await open()
            return try await exchange(method, params, timeout: timeout)
        }
    }

    /// `initialize`, then `notifications/initialized`: once, whoever asks
    /// first, the others waiting on it.
    private func open() async throws {
        if let opening { return try await opening.value }
        let task = Task {
            _ = try await self.exchange("initialize", .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("visor"), "version": .string("1")]),
            ]), timeout: 30)
            _ = try? await self.post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), timeout: 15)
        }
        opening = task
        do {
            try await task.value
        } catch {
            opening = nil
            throw error
        }
    }

    private func exchange(_ method: String, _ params: JSONValue, timeout: Double) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let answer = try await post(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]),
                                    timeout: timeout)
        if answer.status == 404, sessionID != nil, method != "initialize" { throw MCPProxyError.sessionGone }
        if let session = answer.headers["mcp-session-id"], !session.isEmpty { sessionID = session }
        guard (200..<300).contains(answer.status) else {
            throw MCPProxyError.http(answer.status, String(decoding: answer.body.prefix(300), as: UTF8.self))
        }
        guard let message = Self.message(in: answer, id: id) else { throw MCPProxyError.unreadable }
        if case .object = message["error"] { throw MCPProxyError.rpc(message["error"]["message"].string ?? "The MCP server refused it.") }
        return message["result"]
    }

    private func post(_ message: JSONValue, timeout: Double) async throws -> OutgoingRequest.Answer {
        var headers = headers
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json, text/event-stream"
        if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
            headers["MCP-Protocol-Version"] = Self.protocolVersion
        }
        let request = OutgoingRequest(url: url, method: "POST", headers: headers, body: Data(message.encoded().utf8), timeout: timeout)
        do {
            return try await ServerPlatform.current.fetching.fetch(request)
        } catch {
            throw MCPProxyError.unreachable(error.localizedDescription)
        }
    }

    /// The answer to request `id`: the body as JSON, or, for an SSE stream,
    /// the event carrying it (an event's `data:` lines joined).
    nonisolated static func message(in answer: OutgoingRequest.Answer, id: Int) -> JSONValue? {
        let text = String(decoding: answer.body, as: UTF8.self)
        guard (answer.headers["content-type"] ?? "").contains("text/event-stream") else { return parseJSON(text) }
        let events = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for event in events {
            let data = event.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop { $0 == " " } }
                .joined(separator: "\n")
            if let message = parseJSON(data), message["id"].int == id { return message }
        }
        return nil
    }
}
