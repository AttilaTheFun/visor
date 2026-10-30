// The MCP servers a computer passes on to its sessions' agents: set over
// REST with the password (never an agent's token), a secret header kept
// with the server's secrets; a session's tools listed under each endpoint's
// name and its calls passed on with its own headers; an endpoint switched
// off for a session; an SSE answer read; a forgotten MCP session begun again.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

/// An MCP server played by the test: what it was sent, kept; answers as
/// the test sets them.
private final class FakeMCPServer: HTTPFetching {
    struct Heard: Sendable {
        let headers: [String: String]
        let message: JSONValue
    }
    let heard = Mutex<[Heard]>([])
    /// Answer `tools/call` with a 404 this many times (a restarted server).
    let forgetting = Mutex(0)

    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        let message = parseJSON(String(decoding: request.body, as: UTF8.self)) ?? .null
        heard.withLock { $0.append(Heard(headers: request.headers, message: message)) }
        let method = message["method"].string ?? ""
        guard let id = message["id"].int else { return .init(status: 202, body: Data()) }
        if method == "tools/call", forgetting.withLock({ left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }) {
            return .init(status: 404, body: Data())
        }
        let result: JSONValue
        switch method {
        case "initialize":
            result = .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])])])
        case "tools/list":
            result = .object(["tools": .array([.object(["name": .string("pr_create"), "description": .string("Opens a pull request."),
                                                        "inputSchema": .object(["type": .string("object")])])])])
        default:
            result = .object(["content": .array([.object(["type": .string("text"),
                                                          "text": .string("made " + (message["params"]["arguments"]["title"].string ?? ""))])])])
        }
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result]).encoded()
        return .init(status: 200, body: Data(body.utf8), headers: ["content-type": "application/json", "mcp-session-id": "mcp-1"])
    }
}

@MainActor
final class MCPProxyTests: ServerTestCase {
    private var server: VisorServer!
    private let endpoint = FakeMCPServer()

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ServerPlatform.current.fetching = endpoint
        server = VisorServer(port: 7979)
        server.password = "pw"
        server.sessions = [SessionRecord(info: SessionInfo(id: "S1", agent: .claude, cwd: "/tmp", title: "Parser", created: 0),
                                         process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])]
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func setEndpoints(_ body: String, bearer: String = "pw") -> HTTPResponse {
        server.route(HTTPRequest(method: "PUT", path: "/api/mcp", headers: ["authorization": "Bearer " + bearer], body: body))
    }

    private let gh = #"{"endpoints":[{"name":"gh","url":"http://127.0.0.1:7470/mcp","headers":[{"name":"API_KEY","value":"key-1","secret":true},{"name":"CLIENT_ID","value":"$SESSION_ID@$SESSION_TITLE"}]}]}"#

    private func ask(_ mode: String, text: String? = nil) async throws -> Envelope {
        var e = Envelope(type: "agent")
        e.mode = mode
        e.text = text
        return await server.answerProxied(e, caller: try XCTUnwrap(server.session("S1")))
    }

    func testTheEndpointsAreSetWithThePasswordAndTheirSecretsKeptApart() throws {
        XCTAssertEqual(setEndpoints(gh, bearer: server.agentToken).status, 403, "an agent could send the secrets anywhere")
        XCTAssertTrue(server.settings.mcpEndpoints.isEmpty)
        XCTAssertEqual(setEndpoints(gh).status, 200)
        let kept = try XCTUnwrap(server.settings.mcpEndpoints.first)
        XCTAssertEqual(kept.headers.map(\.value), ["", "$SESSION_ID@$SESSION_TITLE"], "a secret's value isn't in the settings")
        XCTAssertEqual(VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY")), "key-1")
        // Read back, a secret says only that it is kept.
        let listed = server.route(HTTPRequest(method: "GET", path: "/api/mcp", headers: ["authorization": "Bearer pw"], body: ""))
        XCTAssertTrue(listed.body.contains("\"kept\":true") && !listed.body.contains("key-1"), listed.body)
        // Set again without its value, the secret stays; dropped, it goes.
        XCTAssertEqual(setEndpoints(gh.replacingOccurrences(of: #""value":"key-1","#, with: "")).status, 200)
        XCTAssertEqual(VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY")), "key-1")
        XCTAssertEqual(setEndpoints(#"{"endpoints":[]}"#).status, 200)
        XCTAssertNil(VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY")))
        // A name its tools couldn't go under is refused.
        XCTAssertEqual(setEndpoints(#"{"endpoints":[{"name":"g__h","url":"http://x/mcp"}]}"#).status, 400)
    }

    func testASessionsToolsAreListedUnderTheEndpointAndCalledWithItsHeaders() async throws {
        XCTAssertEqual(setEndpoints(gh).status, 200)
        XCTAssertEqual(server.session("S1")?.info.mcp, [MCPSwitch(name: "gh", on: true)])

        let listed = try await ask("mcp_tools")
        let tools = try XCTUnwrap(parseJSON(listed.text ?? "")?.array)
        XCTAssertEqual(tools.map { $0["name"].string }, ["gh__pr_create"])
        XCTAssertEqual(tools.first?["description"].string, "Opens a pull request.")

        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{"title":"Sub-sessions"}}"#)
        XCTAssertNil(called.error)
        XCTAssertEqual(parseJSON(called.text ?? "")?["content"][0]["text"].string, "made Sub-sessions")

        let heard = endpoint.heard.withLock { $0 }
        XCTAssertEqual(heard.compactMap { $0.message["method"].string },
                       ["initialize", "notifications/initialized", "tools/list", "tools/call"], "initialized once, then asked")
        let call = try XCTUnwrap(heard.last)
        XCTAssertEqual(call.message["params"]["name"].string, "pr_create", "under its own name")
        XCTAssertEqual(call.headers["API_KEY"], "key-1")
        XCTAssertEqual(call.headers["CLIENT_ID"], "S1@Parser", "the session filled in")
        XCTAssertEqual(call.headers["Mcp-Session-Id"], "mcp-1", "the MCP session it was given")
    }

    func testASessionSwitchesAnEndpointOff() async throws {
        XCTAssertEqual(setEndpoints(gh).status, 200)
        server.perform(.mcp(session: "S1", endpoint: "gh", on: false), from: nil)
        let record = try XCTUnwrap(server.session("S1"))
        XCTAssertEqual(record.info.mcp, [MCPSwitch(name: "gh", on: false)])
        XCTAssertEqual(record.stored.mcpSwitched, ["gh": false])
        let listed = try await ask("mcp_tools")
        XCTAssertEqual(listed.text, "[]")
        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{}}"#)
        XCTAssertEqual(called.error, "No MCP server gh for this session.")
        // On again, back to its default: nothing kept for it.
        server.perform(.mcp(session: "S1", endpoint: "gh", on: true), from: nil)
        XCTAssertNil(record.stored.mcpSwitched)
    }

    func testAForgottenMCPSessionIsBegunAgain() async throws {
        XCTAssertEqual(setEndpoints(gh).status, 200)
        _ = try await ask("mcp_tools")
        endpoint.forgetting.withLock { $0 = 1 }
        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{"title":"Again"}}"#)
        XCTAssertEqual(parseJSON(called.text ?? "")?["content"][0]["text"].string, "made Again")
        let methods = endpoint.heard.withLock { $0.compactMap { $0.message["method"].string } }
        XCTAssertEqual(methods.suffix(4), ["tools/call", "initialize", "notifications/initialized", "tools/call"])
    }

    func testAProxiedCallIsShownByItsServerAndName() {
        XCTAssertEqual(MCPProxy.shownName("mcp__visor__gh__pr_create"), "gh: pr_create")
        XCTAssertEqual(MCPProxy.shownName("gh__pr_create"), "gh: pr_create", "as Codex names it")
        XCTAssertNil(MCPProxy.shownName("mcp__visor__send_message"), "Visor's own")
        XCTAssertEqual(ClaudeOutput.label(name: "mcp__visor__gh__pr_create", input: ["title": "Sub-sessions"]), "gh: pr_create — Sub-sessions")
    }

    func testAnAnswerAsAnSSEStreamIsRead() {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
            + "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\n"
            + "data: \"result\":{\"ok\":true}}\n\n"
        let answer = OutgoingRequest.Answer(status: 200, body: Data(body.utf8), headers: ["content-type": "text/event-stream"])
        XCTAssertEqual(MCPConnection.message(in: answer, id: 3)?["result"]["ok"].bool, true, "its data lines joined")
        XCTAssertNil(MCPConnection.message(in: answer, id: 4))
    }
}
