// gh_mcp's MCP server (AttilaTheFun/gh_mcp, archived at #12; Logan,
// 2026-11-21: "fold gh_mcp into Visor's agent-proxy at /mcp/gh, retire the
// LaunchAgent and binary"), answered inside agent-proxy at `/mcp/gh` on its
// loopback port (7439) rather than on a listener of its own (7470). What a
// session sees is gh_mcp's: the same tools, descriptions and schemas, the
// same answers and errors, the same rules.
//
// What changed is who the caller is. gh_mcp took a key (`API_KEY`) that
// named an application and the agent it acts as; here agent-proxy has
// already let the call through with the sessions' token (`X-Visor-Proxy`),
// so there is no key: the caller is the session its `CLIENT_ID` names (the
// session's own id since Visor #482), and the agent (the GitHub App it acts
// as) is the settings' for that session, else theirs for every session
// (logan-shire-agent unless said).

import Foundation

/// gh_mcp's version as it served it: its serverInfo and GitHub's
/// User-Agent say it.
public let serverVersion = "0.1.0"

/// MCP over Streamable HTTP: JSON-RPC 2.0 posted to agent-proxy's
/// `/mcp/gh`, answered with plain JSON (no SSE streams, no sessions).
/// `CLIENT_ID` names the caller.
public final class MCPServer: Sendable {
    /// Newest first; a client asking for one of these gets it, others the
    /// newest.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// What the call log names after `@`: where the call came from (gh_mcp's
    /// was the key's application, e.g. `mac-mini-cotenant-runner`).
    public static let application = "visor"

    /// What the calls may touch and whom they act as, as the settings say
    /// now.
    public struct Configuration: Sendable, Equatable {
        /// The repositories its tools may touch: `Owner/*` or `Owner/name`.
        public var repositories: [String]
        /// The agent every session acts as unless `sessionAgents` names
        /// another: claude, codex or agent (AgentApps).
        public var agent: String
        /// Agents by session id (CLIENT_ID).
        public var sessionAgents: [String: String]

        public static let defaultRepositories = ["AttilaTheFun/*"]

        public init(repositories: [String] = Configuration.defaultRepositories, agent: String = "agent", sessionAgents: [String: String] = [:]) {
            self.repositories = repositories
            self.agent = agent
            self.sessionAgents = sessionAgents
        }

        /// The agent a call from `client` acts as.
        public func agent(for client: String?) -> String {
            client.flatMap { sessionAgents[$0] } ?? agent
        }
    }

    let configuration: @Sendable () -> Configuration
    let services: Services
    let log: CallLog
    let toolbox = Toolbox()

    /// `configuration` is asked at each call, so a change to the settings
    /// counts at the next one.
    public init(configuration: @escaping @Sendable () -> Configuration, services: Services, log: CallLog) {
        self.configuration = configuration
        self.services = services
        self.log = log
    }

    public func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.method == "POST" else {
            // No server-sent stream to GET: answers come back on the POST.
            return MCPHTTPResponse(status: 405, headers: ["Allow": "POST", "Content-Type": "text/plain; charset=utf-8"],
                                   body: Data("gh_mcp takes POST /mcp only\n".utf8))
        }
        if let origin = request.header("origin"), !Self.isLocalOrigin(origin) {
            return .text("Forbidden: requests from web pages are refused", status: 403)
        }
        let config = configuration()
        let client = Self.clientID(request)
        let caller = Caller(application: Self.application, agent: config.agent(for: client), client: client)
        let message: JSON
        do {
            message = try JSON.parse(request.body)
        } catch {
            return .json(Self.error(id: .null, code: -32700, message: "Parse error: the body is not JSON"), status: 400)
        }
        let rules = RepoRules(config.repositories)
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return .json(Self.error(id: .null, code: -32600, message: "Invalid Request: an empty batch"), status: 400) }
            var responses: [JSON] = []
            for item in batch {
                if let response = await respond(to: item, caller: caller, rules: rules) { responses.append(response) }
            }
            return responses.isEmpty ? MCPHTTPResponse(status: 202) : .json(.array(responses))
        }
        guard let response = await respond(to: message, caller: caller, rules: rules) else { return MCPHTTPResponse(status: 202) }
        return .json(response)
    }

    /// One JSON-RPC message's answer: nil for a notification (or a client's
    /// response), which gets none.
    func respond(to message: JSON, caller: Caller, rules: RepoRules) async -> JSON? {
        guard case .object(let fields) = message, fields["jsonrpc"]?.stringValue == "2.0" else {
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request: not a JSON-RPC 2.0 message")
        }
        guard let method = fields["method"]?.stringValue else {
            // A response to a request of the server's: it sends none.
            if fields["result"] != nil || fields["error"] != nil { return nil }
            return Self.error(id: fields["id"] ?? .null, code: -32600, message: "Invalid Request: no method")
        }
        guard let id = fields["id"] else { return nil }
        guard id.stringValue != nil || id.intValue != nil else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request: an id is a string or a number")
        }
        let params = fields["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "gh_mcp", "title": "GitHub for agents", "version": .string(serverVersion)],
                "instructions": .string(instructions(caller: caller, rules: rules)),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            // The catalog alone: no token, GitHub or settings file is asked,
            // so a list never waits (Visor's MCPProxy gives each endpoint 5 s).
            return Self.result(id: id, ["tools": .array(toolbox.tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Invalid params: tools/call names a tool (params.name)")
            }
            guard let tool = toolbox.tool(named: name) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(Redact.line(name, limit: 80))")
            }
            let outcome = await toolbox.call(tool, arguments: params["arguments"] ?? .null, caller: caller, rules: rules, services: services)
            log.record(caller: caller.label, tool: tool.name, repo: outcome.repo, outcome: outcome.logOutcome)
            return Self.result(id: id, [
                "content": [["type": "text", "text": .string(outcome.text)]],
                "isError": .bool(outcome.isError),
            ])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(Redact.line(method, limit: 80))")
        }
    }

    func instructions(caller: Caller, rules: RepoRules) -> String {
        """
        gh_mcp is GitHub for coding agents: it acts as the logan-shire-\(caller.agent) GitHub App, so no GitHub \
        credential is needed in the session. It touches only \(rules.patterns.joined(separator: ", ")). Commit \
        with git as usual, then push with git_push (a branch of your own: never main, master, the default branch \
        or a tag; force only with force_with_lease), open and update pull requests (pr_create, pr_edit, \
        pr_comment, pr_view, pr_list), follow CI (checks, runs, run_view, run_log, artifact_download) and draft \
        releases (release_draft, release_edit_draft, release_list). It never merges, tags, publishes, deletes or \
        administers: those are a person's. repo_file reads a file on GitHub.
        """
    }

    static func result(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    /// `CLIENT_ID`, kept to 64 letters, digits and `._:-`.
    static func clientID(_ request: MCPHTTPRequest) -> String? {
        guard let raw = request.header("client-id")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where kept.count < 64 {
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:-".unicodeScalars.contains(scalar)) {
                kept.append(scalar)
            }
        }
        return kept.isEmpty ? nil : String(kept)
    }

    /// A browser's request (DNS rebinding) carries the page's Origin; only
    /// this computer's own are taken.
    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}
