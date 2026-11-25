// Where the Sessions container's agents reach agent-proxy's MCP
// pass-through (docs/containers.md, "MCP in the container"; 0.72.1): each
// server it serves, by its name, at `http://mcp.agent.internal/mcp/<name>`,
// the relay's dial-in to the pass-through (agent-proxy's
// DialIn.passThrough). Of those, a container's Claude is told of Nimbus's
// alone (ContainerClaudeMCP.served; Logan, 25 Nov 2026), and the
// pass-through refuses its agents any other.

import Foundation

extension AgentProxySettings {
    /// The pass-through's name in a container: agent-proxy's own dial-in,
    /// on port 80.
    public static let passThroughHost = "mcp.agent.internal"
    /// gh_mcp's name at the pass-through, where it's answered in-process
    /// (VisorAgentProxyHost's GitHubMCP.name).
    static let inProcessGitHub = "gh"

    /// The servers the pass-through serves, as its settings say: each
    /// upstream's name, then gh_mcp's where it's answered in-process (`gh`
    /// set, and no upstream of that name). None without a pass-through.
    /// Each once, and only a name a URL's path takes as one segment.
    public var passThroughServers: [String] {
        guard mcp != nil || gh != nil else { return [] }
        var names = (mcp?.upstreams ?? []).map(\.name)
        if gh != nil, !names.contains(Self.inProcessGitHub) { names.append(Self.inProcessGitHub) }
        var seen = Set<String>()
        return names.filter { Self.isServerName($0) && seen.insert($0).inserted }
    }

    /// Where a container's agents reach the pass-through's `server`.
    public static func containerURL(of server: String) -> String {
        "http://\(passThroughHost)/mcp/\(server)"
    }

    /// Whether `name` is one path segment: letters, digits, `.`, `_` and
    /// `-`, and neither `.` nor `..`.
    static func isServerName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.count <= 64
            && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" || $0 == "-" }
    }
}
