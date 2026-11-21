import Foundation
import VisorProtocol

/// Visor's MCP server, request by request, as the Node script answered
/// them: `initialize`, the tools' list (Visor's own, `approve` where asked
/// for, and the MCP servers the computer passes on to the session, looked
/// at again every 30 s and the agent told when they change; none for an
/// agent in a container), their calls (to the server, or for `approve` to the
/// person), `ping`. Every call goes
/// to the server through its link; what the agent is told goes out a line
/// at a time.
///
/// The tools' list is answered at once, from the passed-on tools as last
/// looked at: Visor's own are always in it, and a look that fails or is
/// slow (the server restarting, an endpoint down) keeps the last good
/// list. The agent is told the list changed only when a look finds tools
/// that differ, as values, from what it was last given (visor 0.65: 0.64
/// compared their JSON as text, whose objects' keys come in no set order,
/// and told it on every look).
package actor MCPBridge {
    private let link: any MCPServerLink
    private let output: any MCPOutput
    /// Whether `approve` is offered (VISOR_APPROVALS).
    private let approvals: Bool
    /// Whether the agent runs in a container (VISOR_URL set).
    private let contained: Bool
    /// Whether the computer's passed-on MCP servers are offered. An agent
    /// in a container (VisorDriver's DrivenMCP) gets only Visor's own tools:
    /// none of them listed, watched or called.
    private let passesOn: Bool
    private let timing: MCPTiming
    /// The passed-on tools as the server last listed them: what the tools'
    /// list answers with at once, kept through a look that fails. Nil until
    /// a look has come back.
    private var proxied: [JSONValue]?
    /// What the agent was last given of the passed-on tools (`signature`):
    /// what a later look is held against.
    private var announced: JSONValue?
    private var watching = false
    /// The look every 30 s at the passed-on tools, until `close`.
    private var watch: Task<Void, Never>?
    /// The `approve` calls waiting on the person, by the agent's request id
    /// (as JSON): each given up when the agent gives up on it.
    private var asking: [String: MCPAsking] = [:]

    package init(link: any MCPServerLink, output: any MCPOutput, approvals: Bool, contained: Bool, passesOn: Bool = true,
                 timing: MCPTiming = MCPTiming()) {
        self.link = link
        self.output = output
        self.approvals = approvals
        self.contained = contained
        self.passesOn = passesOn
        self.timing = timing
    }

    /// One line from the agent: a request, or a notification.
    package func handle(_ line: String) {
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
                "instructions": .string(MCPTools.instructions(contained: contained, passesOn: passesOn)),
            ]))
        case "notifications/initialized":
            if passesOn { watchProxied() }
        case "notifications/cancelled":
            asking[params["requestId"].encoded()]?.cancel("cancelled")
        case "tools/list":
            guard passesOn else { return listTools(id, []) }
            if let proxied { return listTools(id, proxied) }
            // The first list: looked at once, within `look`; Visor's own
            // alone if that fails, the rest said when a look finds them.
            Task {
                if proxied == nil, let looked = await lookAtProxied() { proxied = looked }
                listTools(id, proxied ?? [])
            }
        case "tools/call":
            let name = params["name"].string ?? ""
            let arguments = params["arguments"].object ?? [:]
            if name.contains("__") {
                guard passesOn else { return respond(id, Self.text(Self.notPassedOn(name), error: true)) }
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

    /// Done with: its look at the passed-on tools stopped. (A bridge whose
    /// process ends with the agent's needs none; one a driver keeps for a
    /// connection does: VisorDriver's DrivenMCP.)
    package func close() {
        watch?.cancel()
        watch = nil
    }

    /// The tools' list: Visor's own, and the passed-on ones given.
    private func listTools(_ id: JSONValue, _ passedOn: [JSONValue]) {
        if passesOn { announced = Self.signature(passedOn) }
        respond(id, .object(["tools": .array((approvals ? [MCPTools.approve] : []) + MCPTools.sessions + passedOn)]))
    }

    private func respond(_ id: JSONValue, _ result: JSONValue) {
        output.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private static func text(_ text: String, error: Bool) -> JSONValue {
        .object(["isError": .bool(error), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    // MARK: The passed-on tools

    /// The session's passed-on tools, from the server, within `look`; nil
    /// when it doesn't say (unreachable, refused, or too slow), so the last
    /// good list is kept rather than taken as none.
    private func lookAtProxied() async -> [JSONValue]? {
        let link = self.link
        let reply = await MCPDeadline.first(within: timing.look) { await link.call(["mode": .string("mcp_tools")]) }
        guard let reply, reply.ok, let tools = parseJSON(reply.text)?.array else { return nil }
        return tools
    }

    /// What a list of tools is held against: each one's name, description
    /// and schema, compared as values (an object's keys in any order).
    static func signature(_ tools: [JSONValue]) -> JSONValue {
        .array(tools.map { tool in
            .array([tool["name"], .string(tool["description"].string ?? ""), tool["inputSchema"]])
        })
    }

    /// A look that came back: kept, and a word to the agent when its tools
    /// differ from what it was last given (and never before its first list).
    private func took(_ tools: [JSONValue]) {
        proxied = tools
        let now = Self.signature(tools)
        guard let announced, now != announced else { return }
        self.announced = now
        output.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))
    }

    /// Every 30 s: the passed-on tools as they are now. A look that fails
    /// keeps the last good list and is tried again sooner, after `retry`,
    /// doubled each time it fails again, up to the 30 s.
    private func watchProxied() {
        guard !watching else { return }
        watching = true
        let timing = self.timing
        watch = Task {
            var failures = 0
            while !Task.isCancelled {
                let wait = failures == 0 ? timing.watch : min(timing.retry * (1 << min(failures - 1, 16)), timing.watch)
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
                guard let tools = await lookAtProxied() else {
                    failures += 1
                    continue
                }
                failures = 0
                took(tools)
            }
        }
    }

    /// Why an agent in a container can't call `name`: it isn't one of Visor's
    /// own tools, and the computer's passed-on servers aren't its.
    static func notPassedOn(_ name: String) -> String {
        "\(name) isn't one of Visor's tools. An agent in a container gets only Visor's own tools here, not the MCP servers this computer passes on to its own sessions; its other MCP servers are its container's."
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
        // "mail": this MCP server has read_inbox, so the server puts what
        // other sessions send this one in its inbox.
        var fields: [String: JSONValue] = ["mode": .string(mode), "version": .string("mail")]
        fields["session"] = session
        fields["server"] = given("server", "server_id")
        fields["messageID"] = given("message_id", "messageID")
        fields["text"] = given("text", "message")
        // read_inbox's read messages too: said to the server as `text`.
        if mode == "inbox", let unreadOnly = arguments["unread_only"], unreadOnly.bool == false || unreadOnly.string == "false" {
            fields["text"] = .string("all")
        }
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
            asks["prompt"] = .string(MCPTools.summary(tool: tool, input: input))
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
