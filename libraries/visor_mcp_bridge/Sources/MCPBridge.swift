import Foundation
import VisorProtocol

/// Visor's MCP server, request by request, as the Node script answered
/// them: `initialize`, the tools' list (Visor's own, `approve` where asked
/// for, and the MCP servers the computer passes on to the session, looked
/// at again every 30 s and the agent told when they change), their calls
/// (to the server, or for `approve` to the person), `ping`. Every call goes
/// to the server through its link; what the agent is told goes out a line
/// at a time.
actor MCPBridge {
    private let link: any MCPServerLink
    private let output: any MCPOutput
    /// Whether `approve` is offered (VISOR_APPROVALS).
    private let approvals: Bool
    /// Whether the agent runs in a container (VISOR_URL set).
    private let contained: Bool
    private let timing: MCPTiming
    /// The passed-on tools as last listed to the agent: what a later look
    /// is held against.
    private var listedProxied: String?
    private var watching = false
    /// The `approve` calls waiting on the person, by the agent's request id
    /// (as JSON): each given up when the agent gives up on it.
    private var asking: [String: MCPAsking] = [:]

    init(link: any MCPServerLink, output: any MCPOutput, approvals: Bool, contained: Bool, timing: MCPTiming = MCPTiming()) {
        self.link = link
        self.output = output
        self.approvals = approvals
        self.contained = contained
        self.timing = timing
    }

    /// One line from the agent: a request, or a notification.
    func handle(_ line: String) {
        guard let request = parseJSON(line), request.object != nil else { return }
        let id = request["id"]
        let params = request["params"]
        switch request["method"].string ?? "" {
        case "initialize":
            let version = params["protocolVersion"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "2024-11-05"
            respond(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                "serverInfo": .object(["name": .string("visor"), "version": .string("1.0")]),
                "instructions": .string(MCPTools.instructions(contained: contained)),
            ]))
        case "notifications/initialized":
            watchProxied()
        case "notifications/cancelled":
            asking[params["requestId"].encoded()]?.cancel("cancelled")
        case "tools/list":
            Task {
                let proxied = await proxiedTools()
                listedProxied = Self.signature(proxied)
                respond(id, .object(["tools": .array((approvals ? [MCPTools.approve] : []) + MCPTools.sessions + proxied)]))
            }
        case "tools/call":
            let name = params["name"].string ?? ""
            let arguments = params["arguments"].object ?? [:]
            if name.contains("__") {
                callProxied(id, name, arguments)
            } else if name != "approve" {
                callSessions(id, name, arguments)
            } else {
                approve(id, arguments, progress: params["_meta"]["progressToken"])
            }
        case "ping":
            respond(id, .object([:]))
        default:
            guard !id.isNull else { return }
            output.send(.object(["jsonrpc": .string("2.0"), "id": id,
                                 "error": .object(["code": .number(-32601), "message": .string("unknown method \(request["method"].string ?? "")")])]))
        }
    }

    private func respond(_ id: JSONValue, _ result: JSONValue) {
        output.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private static func text(_ text: String, error: Bool) -> JSONValue {
        .object(["isError": .bool(error), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    // MARK: The passed-on tools

    /// The session's passed-on tools, from the server; none when it can't say.
    private func proxiedTools() async -> [JSONValue] {
        let reply = await link.call(["mode": .string("mcp_tools")])
        guard reply.ok else { return [] }
        return parseJSON(reply.text)?.array ?? []
    }

    /// What a list of tools is held against: each one's name, description
    /// and schema.
    static func signature(_ tools: [JSONValue]) -> String {
        JSONValue.array(tools.map { tool in
            .array([tool["name"], .string(tool["description"].string ?? ""), tool["inputSchema"]])
        }).encoded()
    }

    /// Every 30 s: the passed-on tools as they are now, and a word to the
    /// agent when they differ from what it was last given.
    private func watchProxied() {
        guard !watching else { return }
        watching = true
        let every = timing.watch
        Task {
            while true {
                try? await Task.sleep(for: every)
                let tools = await proxiedTools()
                let now = Self.signature(tools)
                if let listed = listedProxied, now != listed {
                    listedProxied = now
                    output.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))
                }
            }
        }
    }

    /// A passed-on tool: the server passes it on, and its result comes back
    /// as the endpoint gave it.
    private func callProxied(_ id: JSONValue, _ name: String, _ arguments: [String: JSONValue]) {
        let request = JSONValue.object(["tool": .string(name), "arguments": .object(arguments)]).encoded()
        Task {
            let reply = await link.call(["mode": .string("mcp_call"), "text": .string(request)])
            guard reply.ok else { return respond(id, Self.text(reply.text, error: true)) }
            respond(id, parseJSON(reply.text) ?? .object(["content": .array([.object(["type": .string("text"), "text": .string(reply.text)])])]))
        }
    }

    // MARK: The other sessions

    /// A session tool, to the server. The names an agent reaches for when
    /// it has lost the schema (session_id, server_id) are taken too; a
    /// session left out is said plainly, not answered as one that doesn't
    /// exist.
    private func callSessions(_ id: JSONValue, _ name: String, _ arguments: [String: JSONValue]) {
        guard let mode = MCPTools.modes[name] else { return respond(id, Self.text("No tool \(name)", error: true)) }
        func given(_ keys: String...) -> JSONValue? { keys.lazy.compactMap { arguments[$0] }.first { !$0.isNull } }
        let session = given("session", "session_id")
        if mode == "send" || mode == "read", session == nil || session == .string("") {
            return respond(id, Self.text("\(name) needs `session` and `server`: a session id and its computer's server id, from list_sessions.", error: true))
        }
        var fields: [String: JSONValue] = ["mode": .string(mode)]
        fields["session"] = session
        fields["server"] = given("server", "server_id")
        fields["messageID"] = given("message_id", "messageID")
        fields["text"] = given("text", "message")
        if let count = arguments["count"] {
            // As JavaScript's Math.round(Number(count)): a number that isn't
            // one goes as null.
            let number = count.double ?? count.string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            fields["rows"] = number.map { .number(($0 + 0.5).rounded(.down)) } ?? .null
        }
        Task {
            let reply = await link.call(fields)
            respond(id, Self.text(reply.text, error: !reply.ok))
        }
    }

    // MARK: Approve

    /// The person's answer to a tool call. Still waiting, said every 20 s
    /// where the agent takes progress; where it doesn't, "not yet" before
    /// it gives up on the call itself. Nothing is answered for a call the
    /// agent gave up on.
    private func approve(_ id: JSONValue, _ arguments: [String: JSONValue], progress token: JSONValue) {
        let asked = MCPAsking()
        let key = id.encoded()
        asking[key] = asked
        let tool = arguments["tool_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
        let input = arguments["input"] ?? .null
        var asks: [String: JSONValue] = ["text": .string(tool)]
        if tool == "AskUserQuestion", let questions = input["questions"].array {
            asks["prompt"] = .string(questions.first?["question"].string ?? "")
            asks["questions"] = .array(questions)
        } else {
            asks["prompt"] = .string(MCPTools.summary(input))
        }
        let request = asks
        let output = self.output
        let timing = self.timing
        Task {
            let heartbeat: Task<Void, Never>? = token.isNull ? nil : Task {
                var beats = 0
                while true {
                    try? await Task.sleep(for: timing.heartbeat)
                    if Task.isCancelled { return }
                    beats += 1
                    output.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                                         "params": .object(["progressToken": token, "progress": .number(Double(beats)),
                                                            "message": .string("Waiting for the person to answer in Visor")])]))
                }
            }
            let deadline: Task<Void, Never>? = token.isNull ? Task {
                try? await Task.sleep(for: timing.unanswered)
                if !Task.isCancelled { asked.cancel("unanswered") }
            } : nil
            let answer = await link.ask(request, asked)
            heartbeat?.cancel()
            deadline?.cancel()
            asking[key] = nil
            if answer.reason == "cancelled" { return }
            respond(id, .object(["content": .array([.object(["type": .string("text"),
                                                              "text": .string(Self.decision(answer, tool: tool, input: input).encoded())])])]))
        }
    }

    /// What Claude Code takes back from its permission prompt: allowed,
    /// with a question's answers in the tool's own input; or denied, and why.
    static func decision(_ answer: MCPAnswer, tool: String, input: JSONValue) -> JSONValue {
        if answer.allow {
            var updated = input.object ?? [:]
            if let answers = answer.answers { updated["answers"] = answers }
            return .object(["behavior": .string("allow"), "updatedInput": .object(updated)])
        }
        let message = answer.reason == "unanswered" ? "The person has not answered in Visor for 25 minutes: go on without this, or ask again later."
            : tool == "AskUserQuestion" ? "The user did not answer from Visor." : "The user denied this from Visor."
        return .object(["behavior": .string("deny"), "message": .string(message)])
    }
}
