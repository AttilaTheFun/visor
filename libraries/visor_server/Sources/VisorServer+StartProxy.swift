// The proxy a server is given where it starts (VISOR_PROXY and
// VISOR_PROXY_TOKEN_FILE, `--proxy`, docs/server-proxy.md): its pushes go
// out at `<proxy>/apns/…`, and each MCP server it is told of (VISOR_MCP) is
// passed on to its agents at `<proxy>/mcp/<name>`; each with this server's
// token for the proxy (X-Visor-Proxy), kept with its secrets. What goes
// where is the proxy's to say, outside the server's environment (Visor
// Runner today, MultiPass in 0.50): the server asks none of it over its API.

import Foundation

extension VisorServer {
    /// The header a proxy knows this server by.
    static let proxyTokenHeader = "X-Visor-Proxy"

    /// Takes the proxy given at start: pushes through it, and the MCP
    /// servers named at its `/mcp/<name>`, in place of any of the same name;
    /// the other MCP servers kept as they are.
    public func useProxy(_ url: String, token: String, mcp names: [String]) {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        let kept = token.isEmpty ? nil : token
        Self.secrets.set(Self.pushProxyTokenKey, kept)
        var next = settings
        next.pushProxy = base
        next.mcpEndpoints.removeAll { names.contains($0.name) }
        for name in names {
            next.mcpEndpoints.append(MCPEndpoint(name: name, url: base + "/mcp/" + name,
                                                 headers: [MCPEndpoint.Header(name: Self.proxyTokenHeader, secret: true)]))
            Self.secrets.set(MCPEndpoint.secretKey(endpoint: name, header: Self.proxyTokenHeader), kept)
        }
        settings = next
    }
}
