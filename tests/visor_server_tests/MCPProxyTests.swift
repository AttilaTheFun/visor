// The MCP servers a computer passes on to its sessions' agents: set over
// REST with the password (never an agent's token), a secret header kept
// with the server's secrets; a session's tools listed under each endpoint's
// name and its calls passed on with its own headers; an endpoint switched
// off for a session; an SSE answer read; a forgotten MCP session begun again;
// none for a driven session (its agent on a runner); an endpoint that goes
// down or is slow keeping its last good tools, asked at once beside the
// others and less often while it fails, and left out only after long.

import Foundation
import Synchronization
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An MCP server played by the test: what it was sent, kept; answers as
/// the test sets them.
private final class FakeMCPServer: HTTPFetching {
    struct Heard: Sendable {
        let url: String
        let headers: [String: String]
        let message: JSONValue
    }
    let heard = Mutex<[Heard]>([])
    /// Answer `tools/call` with a 404 this many times (a restarted server).
    let forgetting = Mutex(0)
    /// The addresses that answer everything with a 502 (an endpoint down
    /// behind agent-proxy).
    let down = Mutex<Set<String>>([])
    /// The addresses that answer nothing: each request waits out its
    /// timeout, and fails.
    let slow = Mutex<Set<String>>([])

    /// The `tools/list` requests sent to `url`.
    func lists(of url: String) -> Int {
        heard.withLock { $0.filter { $0.url == url && $0.message["method"].string == "tools/list" }.count }
    }

    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        let message = parseJSON(String(decoding: request.body, as: UTF8.self)) ?? .null
        heard.withLock { $0.append(Heard(url: request.url, headers: request.headers, message: message)) }
        let method = message["method"].string ?? ""
        if slow.withLock({ $0.contains(request.url) }) {
            try? await Task.sleep(for: .seconds(request.timeout))
            throw CancellationError()
        }
        if down.withLock({ $0.contains(request.url) }) {
            return .init(status: 502, body: Data("\(request.url) doesn't answer.".utf8))
        }
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

extension ServerTests {
@Suite @MainActor final class MCPProxyTests {
    private var server: VisorServer!
    private let endpoint = FakeMCPServer()

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ServerPlatform.current.fetching = endpoint
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        server.sessions = [SessionRecord(info: SessionInfo(id: "S1", agent: .claude, cwd: "/tmp", title: "Parser", created: 0),
                                         process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])]
    }

    isolated deinit {
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
        return await server.answerProxied(e, caller: try #require(server.session("S1")))
    }

    @Test func testTheEndpointsAreSetWithThePasswordAndTheirSecretsKeptApart() throws {
        #expect(setEndpoints(gh, bearer: server.agentToken(for: "S1")).status == 401, "an agent could send the secrets anywhere")
        #expect(server.settings.mcpEndpoints.isEmpty)
        #expect(setEndpoints(gh).status == 200)
        let kept = try #require(server.settings.mcpEndpoints.first)
        #expect(kept.headers.map(\.value) == ["", "$SESSION_ID@$SESSION_TITLE"], "a secret's value isn't in the settings")
        #expect((VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY"))) == "key-1")
        // Read back, a secret says only that it is kept.
        let listed = server.route(HTTPRequest(method: "GET", path: "/api/mcp", headers: ["authorization": "Bearer pw"], body: ""))
        #expect(listed.body.contains("\"kept\":true") && !listed.body.contains("key-1"), Comment(rawValue: listed.body))
        // Set again without its value, the secret stays; dropped, it goes.
        #expect((setEndpoints(gh.replacingOccurrences(of: #""value":"key-1","#, with: "")).status) == 200)
        #expect((VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY"))) == "key-1")
        #expect(setEndpoints(#"{"endpoints":[]}"#).status == 200)
        #expect((VisorServer.secrets.get(MCPEndpoint.secretKey(endpoint: "gh", header: "API_KEY"))) == nil)
        // A name its tools couldn't go under is refused.
        #expect(setEndpoints(#"{"endpoints":[{"name":"g__h","url":"http://x/mcp"}]}"#).status == 400)
    }

    @Test func testASessionsToolsAreListedUnderTheEndpointAndCalledWithItsHeaders() async throws {
        #expect(setEndpoints(gh).status == 200)
        #expect((server.session("S1")?.info.mcp) == [MCPSwitch(name: "gh", on: true)])

        let listed = try await ask("mcp_tools")
        let tools = try #require(parseJSON(listed.text ?? "")?.array)
        #expect((tools.map { $0["name"].string }) == ["gh__pr_create"])
        #expect((tools.first?["description"].string) == "Opens a pull request.")

        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{"title":"Sub-sessions"}}"#)
        #expect(called.error == nil)
        #expect((parseJSON(called.text ?? "")?["content"][0]["text"].string) == "made Sub-sessions")

        let heard = endpoint.heard.withLock { $0 }
        #expect((heard.compactMap { $0.message["method"].string }) == ["initialize", "notifications/initialized", "tools/list", "tools/call"], "initialized once, then asked")
        let call = try #require(heard.last)
        #expect((call.message["params"]["name"].string) == "pr_create", "under its own name")
        #expect((call.headers["API_KEY"]) == "key-1")
        #expect((call.headers["CLIENT_ID"]) == "S1@Parser", "the session filled in")
        #expect((call.headers["Mcp-Session-Id"]) == "mcp-1", "the MCP session it was given")
    }

    /// A remote's URL names its GitHub repository, as owner/name; any other
    /// host's, or a path that isn't owner/name, none.
    @Test func testARemoteNamesItsGitHubRepository() {
        #expect(GitHubRepository.name(ofRemote: "https://github.com/AttilaTheFun/visor.git") == "AttilaTheFun/visor")
        #expect(GitHubRepository.name(ofRemote: "git@github.com:AttilaTheFun/agent_ui.git\n") == "AttilaTheFun/agent_ui")
        #expect(GitHubRepository.name(ofRemote: "ssh://git@github.com/AttilaTheFun/shireworks") == "AttilaTheFun/shireworks")
        #expect(GitHubRepository.name(ofRemote: "https://gitlab.com/AttilaTheFun/visor.git") == nil)
        #expect(GitHubRepository.name(ofRemote: "https://github.com/AttilaTheFun") == nil)
        #expect(GitHubRepository.name(ofRemote: "https://github.com/AttilaTheFun/visor/tree/main") == nil)
        #expect(GitHubRepository.name(ofRemote: "/Users/logan/Developer/visor") == nil)
    }

    /// `$SESSION_REPOSITORY` in a header is the repository the session's
    /// folder is a checkout of; empty for a folder that is none.
    @Test func testAHeaderNamesTheSessionsRepository() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-repo-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for arguments in [["init", "-q"], ["remote", "add", "origin", "git@github.com:AttilaTheFun/visor.git"]] {
            let ran = await ProjectSurvey.git(arguments, in: folder)
            #expect(ran != nil, "git \(arguments.joined(separator: " "))")
        }
        let keymaster = #"{"endpoints":[{"name":"keymaster","url":"http://127.0.0.1:7450/mcp","headers":[{"name":"Keymaster-Repository","value":"$SESSION_REPOSITORY"}]}]}"#
        #expect(setEndpoints(keymaster).status == 200)

        _ = try await ask("mcp_tools")
        #expect((endpoint.heard.withLock { $0.last }?.headers["Keymaster-Repository"]) == "", "/tmp is no checkout")

        server.sessions = [SessionRecord(info: SessionInfo(id: "S1", agent: .claude, cwd: folder, title: "Parser", created: 0),
                                         process: ClaudeProcess(cwd: folder, skipPermissions: true, resume: nil), entries: [])]
        _ = try await ask("mcp_tools")
        #expect((endpoint.heard.withLock { $0.last }?.headers["Keymaster-Repository"]) == "AttilaTheFun/visor")
    }

    @Test func testASessionSwitchesAnEndpointOff() async throws {
        #expect(setEndpoints(gh).status == 200)
        server.perform(.mcp(session: "S1", endpoint: "gh", on: false), from: nil)
        let record = try #require(server.session("S1"))
        #expect(record.info.mcp == [MCPSwitch(name: "gh", on: false)])
        #expect(record.stored.mcpSwitched == ["gh": false])
        let listed = try await ask("mcp_tools")
        #expect(listed.text == "[]")
        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{}}"#)
        #expect(called.error == "No MCP server gh for this session.")
        // On again, back to its default: nothing kept for it.
        server.perform(.mcp(session: "S1", endpoint: "gh", on: true), from: nil)
        #expect(record.stored.mcpSwitched == nil)
    }

    /// A driven session in a container gets none of them, though its
    /// switch is on; one on Visor's own native runner, and a native one
    /// beside it, still have them.
    @Test func testAContainerSessionHasNoPassedOnServers() async throws {
        #expect(setEndpoints(gh).status == 200)
        let driven = SessionRecord(info: SessionInfo(id: "D1", agent: .claude, cwd: "/tmp", title: "Runner", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        driven.driven = true
        server.sessions.append(driven)
        #expect(driven.info.mcp == [MCPSwitch(name: "gh", on: true)], "its switch says on")

        func ask(_ mode: String, as caller: SessionRecord, text: String? = nil) async -> Envelope {
            var e = Envelope(type: "agent")
            e.mode = mode
            e.text = text
            return await server.answerProxied(e, caller: caller)
        }
        let listed = await ask("mcp_tools", as: driven)
        #expect(listed.text == "[]")
        let called = await ask("mcp_call", as: driven, text: #"{"tool":"gh__pr_create","arguments":{"title":"Sub-sessions"}}"#)
        #expect(called.error?.contains("runs in a container") ?? false, Comment(rawValue: called.error ?? "no error"))
        #expect(endpoint.heard.withLock { $0.isEmpty }, "the endpoint never asked for it")

        // Driven, on Visor's own native runner: as any native session.
        let onNativeRunner = SessionRecord(info: SessionInfo(id: "D2", agent: .claude, cwd: "/tmp", title: "Native runner", created: 0),
                                           process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        onNativeRunner.driven = true
        onNativeRunner.runsInContainer = false
        server.sessions.append(onNativeRunner)
        let nativeRunner = await ask("mcp_tools", as: onNativeRunner)
        #expect((parseJSON(nativeRunner.text ?? "")?.array?.map { $0["name"].string }) == ["gh__pr_create"], "a native runner's session has them")

        let native = try await self.ask("mcp_tools")
        #expect((parseJSON(native.text ?? "")?.array?.map { $0["name"].string }) == ["gh__pr_create"], "a native session's are unchanged")
    }

    @Test func testAForgottenMCPSessionIsBegunAgain() async throws {
        #expect(setEndpoints(gh).status == 200)
        _ = try await ask("mcp_tools")
        endpoint.forgetting.withLock { $0 = 1 }
        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{"title":"Again"}}"#)
        #expect((parseJSON(called.text ?? "")?["content"][0]["text"].string) == "made Again")
        let methods = endpoint.heard.withLock { $0.compactMap { $0.message["method"].string } }
        #expect(methods.suffix(4) == ["tools/call", "initialize", "notifications/initialized", "tools/call"])
    }

    /// An endpoint that goes down: its last good tools listed still, and a
    /// call to it failing with why; asked again after 2 s, then 4 s and so
    /// on; left out only once it has been down 15 minutes; and listed again
    /// when it answers.
    @Test func testAnEndpointDownKeepsItsLastGoodToolsUntilLongGone() async throws {
        #expect(setEndpoints(gh).status == 200)
        let url = "http://127.0.0.1:7470/mcp"
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        server.mcpProxy.now = { clock }
        func names() async throws -> [String?] { parseJSON(try await ask("mcp_tools").text ?? "")?.array?.map { $0["name"].string } ?? [] }
        #expect(try await names() == ["gh__pr_create"])

        endpoint.down.withLock { _ = $0.insert(url) }
        #expect(try await names() == ["gh__pr_create"], "its last good tools")
        let called = try await ask("mcp_call", text: #"{"tool":"gh__pr_create","arguments":{"title":"Down"}}"#)
        #expect(called.error?.contains("502") ?? false, Comment(rawValue: called.error ?? "no error"))
        let asked = endpoint.lists(of: url)
        clock += 1
        #expect(try await names() == ["gh__pr_create"])
        #expect(endpoint.lists(of: url) == asked, "not asked again within its 2 s")
        clock += 1.5
        #expect(try await names() == ["gh__pr_create"])
        #expect(endpoint.lists(of: url) == asked + 1, "asked again after 2 s")
        clock += 3
        _ = try await names()
        #expect(endpoint.lists(of: url) == asked + 1, "then not for 4 s")
        clock += 1.5
        _ = try await names()
        #expect(endpoint.lists(of: url) == asked + 2)

        clock += 14 * 60
        #expect(try await names() == ["gh__pr_create"], "down 14 minutes: still listed")
        clock += 2 * 60
        #expect(try await names() == [], "down 16 minutes: left out")

        endpoint.down.withLock { $0.removeAll() }
        clock += 61
        #expect(try await names() == ["gh__pr_create"], "back once it answers")
        clock += 1
        _ = try await names()
        #expect(endpoint.lists(of: url) == asked + 6, "and asked every time again")
    }

    /// Two endpoints asked at once: one that answers nothing costs the
    /// list only its short limit, the other's tools listed beside its
    /// never-answered none; once it answers, both.
    @Test func testASlowEndpointDoesntHoldUpTheList() async throws {
        let two = #"{"endpoints":[{"name":"gh","url":"http://127.0.0.1:7470/mcp"},{"name":"oss","url":"http://mac.local:7481/oss"}]}"#
        #expect(setEndpoints(two).status == 200)
        server.mcpProxy.listTimeout = 0.3
        endpoint.slow.withLock { _ = $0.insert("http://mac.local:7481/oss") }
        let began = Date()
        let listed = try await ask("mcp_tools")
        #expect(Date().timeIntervalSince(began) < 2, "within its limit, not each endpoint's in turn")
        #expect((parseJSON(listed.text ?? "")?.array?.map { $0["name"].string }) == ["gh__pr_create"])
        endpoint.slow.withLock { $0.removeAll() }
        try await Task.sleep(for: .seconds(2.1))
        let both = try await ask("mcp_tools")
        #expect((parseJSON(both.text ?? "")?.array?.map { $0["name"].string }) == ["gh__pr_create", "oss__pr_create"])
    }

    @Test func testAProxiedCallIsShownByItsServerAndName() {
        #expect(VisorMCP.shownName("mcp__visor__gh__pr_create") == "gh: pr_create")
        #expect(VisorMCP.shownName("gh__pr_create") == "gh: pr_create", "as Codex names it")
        #expect(VisorMCP.shownName("mcp__visor__send_message") == nil, "Visor's own")
        #expect(ClaudeOutput.label(name: "mcp__visor__gh__pr_create", input: ["title": "Sub-sessions"]) == "gh: pr_create — Sub-sessions")
    }

    @Test func testAnAnswerAsAnSSEStreamIsRead() {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
            + "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\n"
            + "data: \"result\":{\"ok\":true}}\n\n"
        let answer = OutgoingRequest.Answer(status: 200, body: Data(body.utf8), headers: ["content-type": "text/event-stream"])
        #expect((MCPConnection.message(in: answer, id: 3)?["result"]["ok"].bool) == true, "its data lines joined")
        #expect(MCPConnection.message(in: answer, id: 4) == nil)
    }
}
}
