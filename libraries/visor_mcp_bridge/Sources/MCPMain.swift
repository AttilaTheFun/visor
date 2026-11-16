import Foundation

/// `visor-agent-host mcp`: Visor's MCP server, as each agent session is
/// given it, on its standard input and output. In place of the Node script
/// the server used to write out (VisorMCPScript), so neither this computer
/// nor a container needs Node: the same program on the Mac (in the app's
/// Helpers) and in every container (mounted from the app at /opt/visor/bin).
///
/// Env: VISOR_PORT, VISOR_TOKEN (the session's agent token),
/// VISOR_SESSION, VISOR_APPROVALS ("1": offer `approve`), and VISOR_URL
/// where the server is not this computer's own (an agent in a container:
/// ws://host:port). Without VISOR_SESSION, VISOR_TOKEN, or VISOR_PORT (and
/// no VISOR_URL), every request is answered with an error naming them
/// (MCPMissingEnvironment).
public enum MCPMain {
    public static func run(_ environment: [String: String]) async -> Int32 {
        // Without its session, its token or its port it would reach Visor
        // as no one: every request is answered with why, and stderr (which
        // Claude Code logs) says it too.
        if let missing = MCPMissingEnvironment(environment) {
            FileHandle.standardError.write(Data(("visor-agent-host mcp: " + missing.message + "\n").utf8))
            let output = MCPStandardOutput()
            for await line in MCPLines.standardInput() { missing.answer(line, to: output) }
            return 1
        }
        func set(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        let url = set("VISOR_URL")
        let link = MCPWebSocketLink(url: url ?? "ws://127.0.0.1:\(set("VISOR_PORT") ?? "7433")",
                                    token: environment["VISOR_TOKEN"] ?? "", session: environment["VISOR_SESSION"] ?? "")
        let bridge = MCPBridge(link: link, output: MCPStandardOutput(), approvals: environment["VISOR_APPROVALS"] == "1",
                               contained: url != nil)
        for await line in MCPLines.standardInput() { await bridge.handle(line) }
        return 0
    }
}
