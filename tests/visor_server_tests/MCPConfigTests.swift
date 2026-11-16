// What an agent's Visor MCP server is given goes on the agent's command
// line (Claude's --mcp-config, Codex's -c), which any `ps` shows: Visor's
// own variables only, never the sign-ins agents/<kind>.env gives the agent;
// and for Claude, whose MCP servers inherit its environment, not even the
// session's token.

import Foundation
@testable import VisorAgent
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class MCPConfigTests {
    init() { TestPlatform.install() }

    @Test func testOnlyVisorsOwnVariablesGoToTheScript() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1",
                       "CLAUDE_CODE_OAUTH_TOKEN": "sign-in", "GH_TOKEN": "git", "PATH": "/usr/bin"]
        #expect(VisorMCP.scriptEnvironment(session, approvals: true) == ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1", "VISOR_APPROVALS": "1"])
    }

    /// The MCP server is this computer's agent host run as `mcp`, where it
    /// is.
    @Test func testTheMCPServerIsTheAgentHostWhereThereIsOne() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents"]
        let host = VisorMCP.launch(session, agentHost: "/bin/sh")
        #expect((host?.command) == "/bin/sh")
        #expect((host?.arguments) == ["mcp"])
        #expect(VisorMCP.launch([:], agentHost: "/bin/sh") == nil, "none for a session with no environment")
        #expect((VisorMCP.launch(session, agentHost: "/nowhere/visor-agent-host")?.arguments) != ["mcp"], "not an agent host that isn't there")
    }

    @Test func testWithoutApprovalsThereIsNoApproveTool() {
        #expect(VisorMCP.scriptEnvironment(["VISOR_PORT": "7433", "OPENAI_API_KEY": "key"], approvals: false) == ["VISOR_PORT": "7433"])
    }

    /// Claude's MCP servers inherit its environment, so its `--mcp-config`
    /// (on its command line) carries no token, port or session: only
    /// whether `approve` is offered.
    @Test func testClaudesConfigCarriesNoToken() throws {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "secret-token", "VISOR_SESSION": "s1"]
        let config = try #require(VisorMCP.claudeConfig(session, approvals: true, inherits: true, agentHost: "/bin/sh"))
        #expect(!config.contains("secret-token"))
        #expect(!config.contains("VISOR_PORT") && !config.contains("VISOR_SESSION"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let visor = try #require((json["mcpServers"] as? [String: Any])?["visor"] as? [String: Any])
        #expect((visor["env"] as? [String: String]) == ["VISOR_APPROVALS": "1"])
        #expect((visor["args"] as? [String]) != nil, "still the server to run")
    }

    /// A CLI that gives its MCP servers only what its config says (the
    /// OpenRouter CLI) still gets Visor's variables there.
    @Test func testAConfigForACLIThatDoesNotInheritCarriesVisorsVariables() throws {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "secret-token", "VISOR_SESSION": "s1"]
        let config = try #require(VisorMCP.claudeConfig(session, approvals: false, inherits: false, agentHost: "/bin/sh"))
        #expect(config.contains("secret-token"))
        #expect(!config.contains("VISOR_APPROVALS"))
    }
}
}
