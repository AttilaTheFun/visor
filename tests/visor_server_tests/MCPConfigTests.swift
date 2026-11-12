// What an agent's Visor MCP server is given goes on the agent's command
// line (Claude's --mcp-config, Codex's -c), which any `ps` shows: Visor's
// own variables only, never the sign-ins agents/<kind>.env gives the agent.

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
}
}
