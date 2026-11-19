// What the relay listener hands to the agent proxy's later phases (Logan,
// 2026-11-14: MultiPass's GitHub interception and MCP proxy move in turn).
// Phase 2 fills GitHubIntercepting with GitHubInterceptor, where
// shireworks-agent-proxy can read its authority and logan-shire-agent's key
// (else GitHub's hosts go through as plain egress: a tunnel, its bytes
// untouched, logged with the route `github`). Phase 3's MCPAnswering was
// ShireworksMCP, dropped in Visor: without one, `/mcp/<name>` answers 404
// (the container runner fills it).

import Foundation

/// GitHub's hosts, which the interceptor opens.
public enum GitHubHosts {
    /// The hosts GitHub's interception covers (GitHubGate.hosts).
    public static let all: Set<String> = ["github.com", "api.github.com", "uploads.github.com"]

    /// Whether `host` (any case) is one of them.
    public static func contains(_ host: String) -> Bool { all.contains(host.lowercased()) }
}
