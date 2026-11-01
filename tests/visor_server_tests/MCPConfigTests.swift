// What an agent's Visor MCP server is given goes on the agent's command
// line (Claude's --mcp-config, Codex's -c), which any `ps` shows: Visor's
// own variables only, never the sign-ins agents/<kind>.env gives the agent.

@testable import VisorServer
import XCTest

final class MCPConfigTests: XCTestCase {
    func testOnlyVisorsOwnVariablesGoToTheScript() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1",
                       "CLAUDE_CODE_OAUTH_TOKEN": "sign-in", "GH_TOKEN": "git", "PATH": "/usr/bin"]
        XCTAssertEqual(VisorMCP.scriptEnvironment(session, container: nil, approvals: true),
                       ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1", "VISOR_APPROVALS": "1"])
    }

    func testWithoutApprovalsThereIsNoApproveTool() {
        XCTAssertEqual(VisorMCP.scriptEnvironment(["VISOR_PORT": "7433", "OPENAI_API_KEY": "key"], container: nil, approvals: false),
                       ["VISOR_PORT": "7433"])
    }
}
