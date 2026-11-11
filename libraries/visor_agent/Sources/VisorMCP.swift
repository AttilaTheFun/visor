// Visor's MCP server, as each agent is told of it: `visor-agent-host mcp`
// (libraries/visor_mcp_bridge), the agents' host program run as an MCP
// server, that gives a session tools to list, message and read the other
// sessions on this computer (and, in Claude's manual mode, the `approve`
// tool the phone answers). Where there is no agent host (Windows), the Node
// script it replaced (VisorMCPScript). The server side of those tools is
// `VisorServer.agentReply`.

import Foundation
import Synchronization
import VisorSystem

enum VisorMCP {
    /// Where the script was written this run, once it has been.
    private static let written = Mutex<String?>(nil)

    /// The script, written into the data directory the first time it is
    /// asked for in a run (again when it differs from what is there).
    static var script: String? {
        written.withLock { path in
            if let path { return path }
            let directory = SystemPlatform.current.host.dataDirectory
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

    /// What runs the MCP server for a session that has its environment
    /// (which is how it reaches this server): this computer's agent host,
    /// as `mcp`; with no agent host here, Node and the script, when both
    /// are here.
    static func launch(_ environment: [String: String],
                       agentHost: String? = SystemPlatform.current.agentHosts?.program) -> (command: String, arguments: [String])? {
        guard !environment.isEmpty else { return nil }
        if let agentHost, FileManager.default.isExecutableFile(atPath: agentHost) { return (agentHost, ["mcp"]) }
        guard let script, let node = ToolPath.resolve("node") else { return nil }
        return (node, [script])
    }

    /// What the script is given: Visor's own variables from the session's
    /// environment (this server's port, the agents' token, the session),
    /// and whether it offers `approve`. Nothing else of the session's: this
    /// goes on the agent's command line, which any `ps` shows, and the rest
    /// is what agents/<kind>.env gives the agent itself — its sign-ins
    /// among it (git's, say).
    static func scriptEnvironment(_ environment: [String: String], approvals: Bool) -> [String: String] {
        var env = environment.filter { $0.key.hasPrefix("VISOR_") }
        if approvals { env["VISOR_APPROVALS"] = "1" }
        return env
    }

    /// Claude's `--mcp-config`: the server as JSON. With `approvals`, the
    /// `approve` tool is offered too, for `--permission-prompt-tool`.
    static func claudeConfig(_ environment: [String: String], approvals: Bool) -> String? {
        guard let launch = launch(environment) else { return nil }
        let env = scriptEnvironment(environment, approvals: approvals)
        let servers: [String: Any] = ["visor": ["command": launch.command, "args": launch.arguments, "env": env]]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Codex's `-c` overrides that add the server.
    static func codexArguments(_ environment: [String: String]) -> [String] {
        guard let launch = launch(environment) else { return [] }
        let env = scriptEnvironment(environment, approvals: false).sorted { $0.key < $1.key }
            .map { "\($0.key)=\(toml($0.value))" }.joined(separator: ", ")
        return ["-c", "mcp_servers.visor.command=\(toml(launch.command))",
                "-c", "mcp_servers.visor.args=[\(launch.arguments.map(toml).joined(separator: ", "))]",
                "-c", "mcp_servers.visor.env={\(env)}"]
    }

    /// A proxied tool (MCPProxy's) as a session's row shows a call of it:
    /// "gh: pr_create" for Claude's `mcp__visor__gh__pr_create` or Codex's
    /// `gh__pr_create`; nil for any other tool.
    static func shownName(_ tool: String) -> String? {
        let name = tool.hasPrefix("mcp__visor__") ? String(tool.dropFirst("mcp__visor__".count)) : tool
        guard let split = name.range(of: "__"), split.lowerBound > name.startIndex else { return nil }
        return name[..<split.lowerBound] + ": " + name[split.upperBound...]
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
