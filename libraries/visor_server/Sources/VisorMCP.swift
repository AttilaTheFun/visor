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
            let file = directory.appendingPathComponent("visor_mcp.js", isDirectory: false)
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
    /// environment (which is how the script reaches the menu bar app). In a
    /// container, the container's node and the script among Visor's tools
    /// there (ContainerTools).
    private static func launch(_ environment: [String: String], container: ContainerPlacement?) -> (node: String, script: String)? {
        guard !environment.isEmpty else { return nil }
        if container != nil { return ("node", ContainerPlacement.scriptPath) }
        guard let script, let node = ToolPath.resolve("node") else { return nil }
        return (node, script)
    }

    /// What the script is given: Visor's own variables from the session's
    /// environment (this server's port, the agents' token, the session),
    /// where this server is when the agent is in a container, and whether
    /// it offers `approve`. Nothing else of the session's: this goes on the
    /// agent's command line, which any `ps` shows, and the rest is what
    /// agents/<kind>.env gives the agent itself — its sign-ins among it (a
    /// container's Claude token, git's).
    static func scriptEnvironment(_ environment: [String: String], container: ContainerPlacement?, approvals: Bool) -> [String: String] {
        var env = environment.filter { $0.key.hasPrefix("VISOR_") }
        if approvals { env["VISOR_APPROVALS"] = "1" }
        if let container { env["VISOR_URL"] = container.serverURL }
        return env
    }

    /// Claude's `--mcp-config`: the server as JSON. With `approvals`, the
    /// `approve` tool is offered too, for `--permission-prompt-tool`.
    static func claudeConfig(_ environment: [String: String], approvals: Bool, container: ContainerPlacement? = nil) -> String? {
        guard let launch = launch(environment, container: container) else { return nil }
        let env = scriptEnvironment(environment, container: container, approvals: approvals)
        let servers: [String: Any] = ["visor": ["command": launch.node, "args": [launch.script], "env": env]]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Codex's `-c` overrides that add the server.
    static func codexArguments(_ environment: [String: String], container: ContainerPlacement? = nil) -> [String] {
        guard let launch = launch(environment, container: container) else { return [] }
        let env = scriptEnvironment(environment, container: container, approvals: false).sorted { $0.key < $1.key }
            .map { "\($0.key)=\(toml($0.value))" }.joined(separator: ", ")
        return ["-c", "mcp_servers.visor.command=\(toml(launch.node))",
                "-c", "mcp_servers.visor.args=[\(toml(launch.script))]",
                "-c", "mcp_servers.visor.env={\(env)}"]
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
