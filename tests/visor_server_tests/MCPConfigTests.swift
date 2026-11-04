// What an agent's Visor MCP server is given goes on the agent's command
// line (Claude's --mcp-config, Codex's -c), which any `ps` shows: Visor's
// own variables only, never the sign-ins agents/<kind>.env gives the agent.

import Foundation
@testable import VisorServer
import XCTest

/// A container's commands, never run.
private struct FakeExec: ContainerExecuting {
    func execute(container: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) { (0, "") }
    func command(container: String, executable: String, arguments: [String], directory: String,
                 environmentFile: String) -> ShellCommand {
        ShellCommand(executable, arguments)
    }
}

final class MCPConfigTests: ServerTestCase {
    func testOnlyVisorsOwnVariablesGoToTheScript() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1",
                       "CLAUDE_CODE_OAUTH_TOKEN": "sign-in", "GH_TOKEN": "git", "PATH": "/usr/bin"]
        XCTAssertEqual(VisorMCP.scriptEnvironment(session, container: nil, approvals: true),
                       ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents", "VISOR_SESSION": "s1", "VISOR_APPROVALS": "1"])
    }

    /// The MCP server is this computer's agent host run as `mcp`, where it
    /// is; a container's is its node and the script among Visor's tools.
    func testTheMCPServerIsTheAgentHostWhereThereIsOne() {
        let session = ["VISOR_PORT": "7433", "VISOR_TOKEN": "agents"]
        let host = VisorMCP.launch(session, container: nil, agentHost: "/bin/sh")
        XCTAssertEqual(host?.command, "/bin/sh")
        XCTAssertEqual(host?.arguments, ["mcp"])
        let placement = ContainerPlacement(id: "c1", serverURL: "ws://192.168.64.1:7433", exec: FakeExec())
        let contained = VisorMCP.launch(session, container: placement, agentHost: "/bin/sh")
        XCTAssertEqual(contained?.command, "node")
        XCTAssertEqual(contained?.arguments, [ContainerPlacement.scriptPath])
        XCTAssertNil(VisorMCP.launch([:], container: nil, agentHost: "/bin/sh"), "none for a session with no environment")
        XCTAssertNotEqual(VisorMCP.launch(session, container: nil, agentHost: "/nowhere/visor-agent-host")?.arguments, ["mcp"],
                          "not an agent host that isn't there")
    }

    func testWithoutApprovalsThereIsNoApproveTool() {
        XCTAssertEqual(VisorMCP.scriptEnvironment(["VISOR_PORT": "7433", "OPENAI_API_KEY": "key"], container: nil, approvals: false),
                       ["VISOR_PORT": "7433"])
    }
}
