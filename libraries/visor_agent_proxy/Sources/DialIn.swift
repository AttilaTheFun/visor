// A dial-in (Visor's docs/server-proxy.md, "Containers: no network"): a
// server on this computer that containers may reach through the relay, by
// a name of the agent proxy's own. A container's
// `CONNECT <name>.agent.internal:<port>` is joined to the server's loopback
// port, byte for byte (gRPC's HTTP/2 included), where the egress proxy
// refuses this computer's addresses. Only the ports a server was given here
// are reached; any other name under `agent.internal` is refused, never
// looked up. One is agent-proxy's own, never the settings':
// `mcp.agent.internal:80`, the MCP pass-through (0.72.1: a container's
// agents get the servers a native session gets). Moved from MultiPass
// (Logan, 2026-11-14); its names
// (`<name>.multipass.internal`) are no longer answered (2026-11-19: no live
// configuration used them, MultiPass archived).

/// A server's port, reachable by containers through the relay.
public struct DialIn: Codable, Equatable, Sendable {
    /// The names' domain: `.internal`, reserved for private names.
    public static let domain = "agent.internal"
    /// Every domain whose names are the agent proxy's own.
    public static let domains = [domain]

    /// The MCP pass-through's own dial-in, which agent-proxy makes itself
    /// wherever it runs the pass-through beside the relay:
    /// `mcp.agent.internal:80`, joined to the pass-through's loopback port
    /// (7439 unless said), so a container's agents reach
    /// `http://mcp.agent.internal/mcp/<name>`. Nothing else on this
    /// computer's loopback is reached by that name.
    public static let passThroughName = "mcp"
    public static let passThroughPort = 80

    /// The pass-through's dial-in, to its loopback port `hostPort`.
    public static func passThrough(to hostPort: Int) -> DialIn {
        DialIn(name: passThroughName, port: passThroughPort, hostPort: hostPort)
    }

    /// The server's name (`visor`), its first label.
    public var name: String
    /// The port containers ask for.
    public var port: Int
    /// The server's port on this computer's loopback.
    public var hostPort: Int

    public init(name: String, port: Int, hostPort: Int) {
        self.name = name
        self.port = port
        self.hostPort = hostPort
    }

    /// The name containers dial: `visor.agent.internal`.
    public var host: String { "\(name).\(Self.domain)" }

    /// Whether `host` (any case) is one of `name`'s: under any of `domains`.
    static func names(_ name: String, _ host: String) -> Bool {
        let host = host.lowercased()
        return domains.contains { host == "\(name).\($0)" }
    }

    /// Whether `host` is under one of the agent proxy's own domains.
    public static func isOwn(_ host: String) -> Bool {
        let host = host.lowercased()
        return domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The dial-in `host`:`port` names, if any.
    public static func matching(_ host: String, _ port: Int, in dialIns: [DialIn]) -> DialIn? {
        dialIns.first { names($0.name, host) && $0.port == port }
    }

    /// A name a dial-in may have: a DNS label of letters, digits and
    /// hyphens, lower case.
    public static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 63 && !name.hasPrefix("-") && !name.hasSuffix("-")
            && name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }
}
