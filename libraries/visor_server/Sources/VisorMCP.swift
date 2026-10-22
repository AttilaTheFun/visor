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
    /// container, the container's node and the script the server wrote
    /// into its home.
    private static func launch(_ environment: [String: String], container: ContainerPlacement?) -> (node: String, script: String)? {
        guard !environment.isEmpty else { return nil }
        if container != nil { return ("node", ContainerPlacement.scriptPath) }
        guard let script, let node = ToolPath.resolve("node") else { return nil }
        return (node, script)
    }

    /// What the script is given: the session's environment, where this
    /// server is when the agent is in a container, and whether it offers
    /// `approve`.
    private static func scriptEnvironment(_ environment: [String: String], container: ContainerPlacement?, approvals: Bool) -> [String: String] {
        var env = environment
        if approvals { env["VISOR_APPROVALS"] = "1" }
        if let container { env["VISOR_URL"] = container.serverURL }
        return env
    }

    /// Claude's `--mcp-config`: the server as JSON. With `approvals`, the
    /// `approve` tool is offered too, for `--permission-prompt-tool`. In a
    /// container, oss's own MCP server beside it (`oss mcp`): the tools an
    /// agent leases machines with (a macOS, Linux or Windows VM, an iOS
    /// simulator, an Android emulator), with the token oss gave its
    /// session.
    static func claudeConfig(_ environment: [String: String], approvals: Bool, container: ContainerPlacement? = nil) -> String? {
        guard let launch = launch(environment, container: container) else { return nil }
        let env = scriptEnvironment(environment, container: container, approvals: approvals)
        var servers: [String: Any] = ["visor": ["command": launch.node, "args": [launch.script], "env": env]]
        if container != nil { servers["oss"] = ["command": "oss", "args": ["mcp"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Codex's `-c` overrides that add the server (and, in a container,
    /// oss's).
    static func codexArguments(_ environment: [String: String], container: ContainerPlacement? = nil) -> [String] {
        guard let launch = launch(environment, container: container) else { return [] }
        let env = scriptEnvironment(environment, container: container, approvals: false).sorted { $0.key < $1.key }
            .map { "\($0.key)=\(toml($0.value))" }.joined(separator: ", ")
        var arguments = ["-c", "mcp_servers.visor.command=\(toml(launch.node))",
                         "-c", "mcp_servers.visor.args=[\(toml(launch.script))]",
                         "-c", "mcp_servers.visor.env={\(env)}"]
        if container != nil { arguments += ["-c", "mcp_servers.oss.command=\(toml("oss"))", "-c", "mcp_servers.oss.args=[\(toml("mcp"))]"] }
        return arguments
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
