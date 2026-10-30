// The MCP servers this server passes on to its sessions' agents
// (MCPEndpoint, MCPProxy): set over REST with the server's password, never
// an agent's token (`GET`/`PUT /api/mcp`), each on or off per session (`mcp`),
// and asked for by Visor's MCP script (`mcp_tools`, `mcp_call`).

import Foundation
import VisorProtocol

extension VisorServer {
    /// The endpoints a session has: each unless it switched it off.
    func mcpEndpoints(for record: SessionRecord) -> [MCPEndpoint] {
        settings.mcpEndpoints.filter { record.mcpSwitched[$0.name] ?? $0.onByDefault }
    }

    /// Each session's `mcp`: the endpoints there are, and whether it has each.
    func fillMCPSwitches() {
        for record in sessions {
            let switches = settings.mcpEndpoints.map { MCPSwitch(name: $0.name, on: record.mcpSwitched[$0.name] ?? $0.onByDefault) }
            if record.info.mcp != switches { record.info.mcp = switches }
        }
    }

    /// `mcp`: an endpoint switched on or off for a session.
    func performMCPSwitch(_ envelope: Envelope, from client: ClientConnection?) {
        guard let record = session(envelope.session), let name = envelope.id, let on = envelope.allow else { return }
        guard let endpoint = settings.mcpEndpoints.first(where: { $0.name == name }) else {
            client?.send(.error("This computer passes on no MCP server \(name)."))
            return
        }
        record.mcpSwitched[name] = on == endpoint.onByDefault ? nil : on
        fillMCPSwitches()
        saveArchive()
        broadcastSessions()
    }

    /// `mcp_tools` and `mcp_call`, from Visor's MCP script: the session's
    /// proxied tools as JSON, or a call's result as its endpoint gave it.
    func answerProxied(_ envelope: Envelope, caller: SessionRecord) async -> Envelope {
        var reply = Envelope(type: "agent_result")
        reply.id = envelope.id
        let endpoints = mcpEndpoints(for: caller)
        switch envelope.mode {
        case "mcp_tools":
            let tools = await mcpProxy.tools(of: endpoints, session: caller.info.id, title: caller.displayName, secrets: Self.secrets)
            reply.text = JSONValue.array(tools).encoded()
        default:
            let asked = parseJSON(envelope.text ?? "") ?? .object([:])
            guard let tool = asked["tool"].string else {
                reply.error = "Which tool?"
                return reply
            }
            do {
                let result = try await mcpProxy.call(tool, arguments: asked["arguments"], endpoints: endpoints, session: caller.info.id,
                                                     title: caller.displayName, secrets: Self.secrets)
                reply.text = result.encoded()
            } catch {
                reply.error = "\(error)"
            }
        }
        return reply
    }

    /// `GET /api/mcp`: the endpoints, a secret header's value left out
    /// (`kept` says whether one is).
    func restMCP(_ call: RESTCall) -> HTTPResponse {
        let endpoints: [JSONValue] = settings.mcpEndpoints.map { endpoint in
            let headers: [JSONValue] = endpoint.headers.map { header in
                var fields: [String: JSONValue] = ["name": .string(header.name), "secret": .bool(header.secret)]
                if header.secret {
                    let kept = Self.secrets.get(MCPEndpoint.secretKey(endpoint: endpoint.name, header: header.name)) ?? ""
                    fields["kept"] = .bool(!kept.isEmpty)
                } else {
                    fields["value"] = .string(header.value)
                }
                return .object(fields)
            }
            return .object(["name": .string(endpoint.name), "url": .string(endpoint.url), "onByDefault": .bool(endpoint.onByDefault),
                            "headers": .array(headers)])
        }
        return .json(JSONValue.object(["endpoints": .array(endpoints)]).encoded())
    }

    /// `PUT /api/mcp {endpoints: [{name, url, onByDefault?, headers: [{name,
    /// value?, secret?}]}]}`: the endpoints, all of them. A secret header's
    /// value goes with the server's secrets; one sent without a value keeps
    /// the value kept. Not with an agent's token: an agent that could move
    /// an endpoint could send its secrets anywhere.
    func restSetMCP(_ call: RESTCall) -> HTTPResponse {
        if !call.request.trusted, call.request.authorization == agentToken {
            return HTTPResponse(403, Envelope.error("An agent can't set this computer's MCP servers.").encoded())
        }
        guard let body = parseJSON(call.request.body), let list = body["endpoints"].array else {
            return HTTPResponse(400, Envelope.error("Send {\"endpoints\": [...]}.").encoded())
        }
        var endpoints: [MCPEndpoint] = []
        var secretValues: [String: String] = [:]
        for item in list {
            let headers = (item["headers"].array ?? []).map { header in
                MCPEndpoint.Header(name: header["name"].string ?? "", value: header["secret"].bool == true ? "" : header["value"].string ?? "",
                                   secret: header["secret"].bool ?? false)
            }
            let endpoint = MCPEndpoint(name: item["name"].string ?? "", url: item["url"].string ?? "", headers: headers,
                                       onByDefault: item["onByDefault"].bool ?? true)
            if let problem = endpoint.problem { return HTTPResponse(400, Envelope.error(problem).encoded()) }
            if endpoints.contains(where: { $0.name == endpoint.name }) {
                return HTTPResponse(400, Envelope.error("Two endpoints are named \(endpoint.name).").encoded())
            }
            for header in item["headers"].array ?? [] where header["secret"].bool == true {
                if let value = header["value"].string, !value.isEmpty, let name = header["name"].string {
                    secretValues[MCPEndpoint.secretKey(endpoint: endpoint.name, header: name)] = value
                }
            }
            endpoints.append(endpoint)
        }
        // Secrets of headers no longer there go; the new ones are kept.
        let wanted = Set(endpoints.flatMap { endpoint in
            endpoint.headers.filter(\.secret).map { MCPEndpoint.secretKey(endpoint: endpoint.name, header: $0.name) }
        })
        for endpoint in settings.mcpEndpoints {
            for header in endpoint.headers where header.secret {
                let key = MCPEndpoint.secretKey(endpoint: endpoint.name, header: header.name)
                if !wanted.contains(key) { Self.secrets.set(key, nil) }
            }
        }
        for (key, value) in secretValues { Self.secrets.set(key, value) }
        settings.mcpEndpoints = endpoints
        return restMCP(call)
    }
}
