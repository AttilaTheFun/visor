// What an agent's Visor MCP server is given goes on the agent's command
// line (Claude's --mcp-config, Codex's -c), which any `ps` shows: Visor's
// own variables only, never the sign-ins agents/<kind>.env gives the agent.

import Foundation
@testable import VisorServer
import XCTest

final class MCPConfigTests: ServerTestCase {
    func testOnlyVisorsOwnVariablesGoToTheScript() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1",
                       "CLAUDE_CODE_OAUTH_TOKEN": "sign-in", "GH_TOKEN": "git", "PATH": "/usr/bin"]
        XCTAssertEqual(VisorMCP.scriptEnvironment(session, approvals: true),
                       ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1", "VISOR_APPROVALS": "1"])
    }

    /// The MCP server is this computer's agent host run as `mcp`, where it
    /// is.
    func testTheMCPServerIsTheAgentHostWhereThereIsOne() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents"]
        let host = VisorMCP.launch(session, agentHost: "/bin/sh")
        XCTAssertEqual(host?.command, "/bin/sh")
        XCTAssertEqual(host?.arguments, ["mcp"])
        XCTAssertNil(VisorMCP.launch([:], agentHost: "/bin/sh"), "none for a session with no environment")
        XCTAssertNotEqual(VisorMCP.launch(session, agentHost: "/nowhere/visor-agent-host")?.arguments, ["mcp"],
                          "not an agent host that isn't there")
    }

    func testWithoutApprovalsThereIsNoApproveTool() {
        XCTAssertEqual(VisorMCP.scriptEnvironment(["VISOR_PORT": "7433", "OPENAI_API_KEY": "key"], approvals: false),
                       ["VISOR_PORT": "7433"])
    }
}
