/// One of the MCP servers a session's computer passes on to its agents
/// (docs/protocol.md, `mcp`), and whether this session has it.
public struct MCPSwitch: Codable, Hashable, Sendable, Identifiable {
    /// The endpoint's name, which its tools are listed under.
    public var name: String
    public var on: Bool

    public var id: String { name }

    public init(name: String, on: Bool) {
        self.name = name
        self.on = on
    }
}
