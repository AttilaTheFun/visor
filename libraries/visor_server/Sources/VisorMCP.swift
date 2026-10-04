// Visor's MCP server, as each agent is told of it: a script (VisorMCPScript)
// run by Node, that gives a session tools to list, message and read the
// other sessions on this computer (and, in Claude's manual mode, the
// `approve` tool the phone answers). The server side of those tools is
// `VisorServer.agentReply`.

import Foundation
import Synchronization

enum VisorMCP {
    /// Where the script was written this run, once it has been.
    private static let written = Mutex<String?>(nil)

    /// The script, written into the data directory the first time it is
    /// asked for in a run (again when it differs from what is there).
    static var script: String? {
        written.withLock { path in
            if let path { return path }
            let directory = ServerPlatform.current.host.dataDirectory
            let file = directory.appendingPathComponent("visor_mcp.js")
            let source = Data(VisorMCPScript.source.utf8)
            if (try? Data(contentsOf: file)) != source {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard (try? source.write(to: file, options: .atomic)) != nil else { return nil }
            }
            path = file.path
            return path
        }
    }

    /// Node and the script, when both are here and the session has its
    /// environment (which is how the script reaches the menu bar app).
    private static func launch(_ environment: [String: String]) -> (node: String, script: String)? {
        guard !environment.isEmpty, let script, let node = ToolPath.resolve("node") else { return nil }
        return (node, script)
    }

    /// Claude's `--mcp-config`: the server as JSON. With `approvals`, the
    /// `approve` tool is offered too, for `--permission-prompt-tool`.
    static func claudeConfig(_ environment: [String: String], approvals: Bool) -> String? {
        guard let launch = launch(environment) else { return nil }
        var env = environment
        if approvals { env["VISOR_APPROVALS"] = "1" }
        let config: [String: Any] = ["mcpServers": ["visor": ["command": launch.node, "args": [launch.script], "env": env]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Codex's `-c` overrides that add the server.
    static func codexArguments(_ environment: [String: String]) -> [String] {
        guard let launch = launch(environment) else { return [] }
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(toml($0.value))" }.joined(separator: ", ")
        return ["-c", "mcp_servers.visor.command=\(toml(launch.node))",
                "-c", "mcp_servers.visor.args=[\(toml(launch.script))]",
                "-c", "mcp_servers.visor.env={\(env)}"]
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
