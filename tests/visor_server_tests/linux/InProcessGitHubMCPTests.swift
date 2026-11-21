// gh_mcp in agent-proxy, as the server's MCPProxy reaches it (0.66): over
// real loopback HTTP, the session's `gh` endpoint at agent-proxy's
// `/mcp/gh`, answered in-process. With #495's lists (each endpoint asked at
// once, within its limit), the in-process endpoint never makes a list wait:
// its tools come from gh_mcp's catalog, with no token, GitHub or settings
// asked, so they answer at once even while a call of the same session's
// waits on agent-token.

import Foundation
@testable import VisorAgent
import VisorAgentProxyHost
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class InProcessGitHubMCPTests {
    private var server: VisorServer!
    private var proxy: AgentProxyHost.Running?
    private var port = 0
    private let folder: URL

    /// gh_mcp's tools, as it named them, under the endpoint's name.
    static let tools = ["git_push", "pr_create", "pr_edit", "pr_comment", "pr_view", "pr_list", "checks", "runs", "run_view", "run_log",
                        "artifact_download", "release_draft", "release_edit_draft", "release_list", "repo_file", "git_fetch",
                        "pr_review_comments", "pr_files", "commits", "commit_view", "compare", "branches", "issues_list", "issue_view",
                        "pr_review_comment_reply", "pr_review", "issue_create", "issue_comment", "issue_edit", "pr_ready_for_review",
                        "pr_update_branch", "pr_merge", "run_rerun", "run_dispatch", "run_cancel"].map { "gh__" + $0 }

    init() async throws {
        TestPlatform.install()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-gh-mcp-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        VisorServer.storeRoot = folder
        VisorServer.secrets = MemorySecrets()
        // agent-token that takes 3 s to give nothing: a call that waits.
        let script = folder.appendingPathComponent("agent-token").path
        try "#!/bin/sh\nsleep 3\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let secrets = MemorySecrets()
        secrets.set("agent-proxy/mcp/token", "sessions-token")
        let places = AgentProxyHost.Places(dataDirectory: folder)
        for _ in 0..<20 where proxy == nil {
            port = Int(ServerTestCase.freePort())
            let settings = AgentProxySettings(mcp: .init(port: port), gh: .init(agentToken: script))
            proxy = AgentProxyHost.start(settings, places: places, secrets: secrets, version: "test", log: { _ in })
            if proxy?.complete == false { proxy?.stop(); proxy = nil }
        }
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
        server.settings.mcpEndpoints = [MCPEndpoint(name: "gh", url: "http://127.0.0.1:\(port)/mcp/gh",
                                                    headers: [.init(name: "X-Visor-Proxy", value: "sessions-token"),
                                                              .init(name: "CLIENT_ID", value: "$SESSION_ID")])]
        server.sessions = ["S1", "S2"].map { id in
            SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: "Parser", created: 0),
                          process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        }
    }

    isolated deinit {
        server.stop()
        proxy?.stop()
    }

    private func ask(_ mode: String, text: String? = nil, session: String = "S1") async throws -> Envelope {
        var e = Envelope(type: "agent")
        e.mode = mode
        e.text = text
        return await server.answerProxied(e, caller: try #require(server.session(session)))
    }

    private func listed(_ session: String) async throws -> [String] {
        let answer = try await ask("mcp_tools", session: session)
        return parseJSON(answer.text ?? "")?.array?.compactMap { $0["name"].string } ?? []
    }

    @Test func theInProcessEndpointNeverMakesTheListWait() async throws {
        try #require(proxy != nil, "agent-proxy's pass-through could listen")
        // A list that waited would fail at its limit and, with no last good
        // list to stand in (none was asked before), list nothing of gh's.
        server.mcpProxy.listTimeout = 1
        // A call of S1's in flight, waiting on agent-token.
        let began = Date()
        let calling = Task { @MainActor in
            try? await self.ask("mcp_call", text: #"{"tool":"gh__pr_list","arguments":{"repo":"AttilaTheFun/visor"}}"#)
        }
        try await Task.sleep(for: .milliseconds(500))
        let asked = Date()
        #expect(try await listed("S1") == Self.tools, "S1's first list, beside its own call")
        #expect(try await listed("S2") == Self.tools, "another session's first list")
        #expect(Date().timeIntervalSince(asked) < 1, "neither waited on the call")
        let called = try #require(await calling.value)
        #expect((called.text ?? "").contains("agent-token gave agent no token"), "\(called.text ?? called.error ?? "")")
        #expect(Date().timeIntervalSince(began) > 2.5, "the call did wait on agent-token")
    }
}
}
