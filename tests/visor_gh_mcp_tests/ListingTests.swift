// What a session sees of gh_mcp is what it saw: tools/list byte for byte as
// gh_mcp served it (fixtures/gh_mcp_tools_list.json, recorded from
// AttilaTheFun/gh_mcp at #12: `gh_mcp serve`, then `tools/list` posted to it
// with a key), its JSON-RPC framing as it came, and initialize's
// instructions naming the session's own app.

import Foundation
import Synchronization
import Testing
@testable import VisorGHMCP

/// gh_mcp's recorded answer, from the test's runfiles.
func recordedListing() throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
    return try Data(contentsOf: URL(fileURLWithPath: "\(root)/tests/visor_gh_mcp_tests/fixtures/gh_mcp_tools_list.json"))
}

@Test func toolsListIsGhMCPsByteForByte() async throws {
    let server = makeServer()
    let answer = await server.handle(MCPHTTPRequest(method: "POST", headers: ["CLIENT_ID": "s1"],
                                                    body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)))
    #expect(answer.status == 200)
    #expect(answer.headers["Content-Type"] == "application/json")
    let recorded = try recordedListing()
    #expect(answer.body == recorded, "tools/list differs from gh_mcp's recorded listing")
    // Its 35 tools, each with its name, description, schema and hints.
    let tools = try #require(try JSON.parse(recorded)["result"]?["tools"]?.arrayValue)
    #expect(tools.count == 35)
    #expect(Toolbox().tools.map(\.name) == tools.compactMap { $0["name"]?.stringValue })
}

@Test func theListingNeverAsksForAToken() async {
    struct Refusing: TokenSource {
        func token(agent: String, owner: String) async throws -> String { throw ToolError.failed("asked") }
    }
    let transport = FakeTransport()
    let server = makeServer(transport: transport, tokens: TokenCache(source: Refusing()))
    let (status, listed) = await post(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    #expect(status == 200 && listed?["result"]?["tools"]?.arrayValue?.count == 35)
    #expect(transport.requests.isEmpty)
    // Nor the settings: only initialize and tools/call read them.
    final class Reads: Sendable { let count = Mutex(0) }
    let reads = Reads()
    let counted = MCPServer(configuration: { reads.count.withLock { $0 += 1 }; return MCPServer.Configuration() },
                            services: Services(transport: transport, tokens: TokenCache(source: Refusing())), log: CallLog(path: nil))
    _ = await post(counted, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
    _ = await post(counted, ["jsonrpc": "2.0", "id": 4, "method": "ping"])
    #expect(reads.count.withLock { $0 } == 0)
    _ = await post(counted, ["jsonrpc": "2.0", "id": 5, "method": "initialize", "params": [:]])
    #expect(reads.count.withLock { $0 } == 1)
}

@Test func jsonRPCFraming() async {
    let server = makeServer()
    let (_, initialized) = await post(server, ["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                               "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]])
    #expect(initialized?["id"] == "a")
    #expect(initialized?["result"]?["protocolVersion"] == "2025-06-18")
    #expect(initialized?["result"]?["capabilities"]?["tools"] != nil)
    #expect(initialized?["result"]?["serverInfo"]?["name"] == "gh_mcp")
    #expect(await post(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]).0 == 202)
    let (_, tools) = await post(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let names = Set((tools?["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    #expect(names == ["git_push", "pr_create", "pr_edit", "pr_comment", "pr_view", "pr_list", "checks", "runs", "run_view",
                      "run_log", "artifact_download", "release_draft", "release_edit_draft", "release_list", "repo_file",
                      "git_fetch", "pr_review_comments", "pr_files", "commits", "commit_view", "compare", "branches", "issues_list",
                      "issue_view", "pr_review_comment_reply", "pr_review", "issue_create", "issue_comment", "issue_edit",
                      "pr_ready_for_review", "pr_update_branch", "pr_merge", "run_rerun", "run_dispatch", "run_cancel"])
    #expect(await post(server, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"]).1?["error"]?["code"] == -32601)
    #expect(await post(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "merge"]]).1?["error"]?["code"] == -32602)
    let parse = await server.handle(MCPHTTPRequest(method: "POST", body: Data("{".utf8)))
    #expect(parse.status == 400 && (try? JSON.parse(parse.body))?["error"]?["code"] == -32700)
    let (_, batch) = await post(server, [["jsonrpc": "2.0", "id": 5, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/initialized"]])
    #expect(batch?.arrayValue?.count == 1)
    #expect(await server.handle(MCPHTTPRequest(method: "GET")).status == 405)
    let page = await server.handle(MCPHTTPRequest(method: "POST", headers: ["Origin": "https://example.com"], body: Data("{}".utf8)))
    #expect(page.status == 403, "a web page's request is refused")
    #expect(MCPServer.clientID(MCPHTTPRequest(method: "POST", headers: ["CLIENT_ID": "sess 42\n"])) == "sess42")
    #expect(Caller(application: MCPServer.application, agent: "agent", client: "s1").label == "s1@visor")
}

@Test func initializeNamesTheSessionsOwnApp() async {
    let server = makeServer(configuration: MCPServer.Configuration(agent: "agent", sessionAgents: ["s-claude": "claude"]))
    let ask: JSON = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]
    let theirs = await post(server, ask, client: "s-claude").1?["result"]?["instructions"]?.stringValue ?? ""
    let others = await post(server, ask, client: "s-other").1?["result"]?["instructions"]?.stringValue ?? ""
    #expect(theirs.contains("acts as the logan-shire-claude GitHub App"))
    #expect(others.contains("acts as the logan-shire-agent GitHub App") && others.contains("It touches only AttilaTheFun/*."))
}
