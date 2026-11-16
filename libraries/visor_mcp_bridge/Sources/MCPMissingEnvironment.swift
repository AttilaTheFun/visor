import VisorProtocol

/// What `visor-agent-host mcp` needs from its environment and wasn't given:
/// `VISOR_SESSION` and `VISOR_TOKEN`, and `VISOR_PORT` unless `VISOR_URL`
/// says where the server is. Claude's MCP config no longer carries them
/// (visor#423): Claude Code passes its own environment, where Visor put
/// them, to its stdio MCP servers. Should it stop, the server says so to
/// every request, rather than reaching Visor as no session.
struct MCPMissingEnvironment: Equatable {
    /// The variables missing (or empty), in the order named above.
    let names: [String]

    /// What is missing from `environment`, if anything is.
    init?(_ environment: [String: String]) {
        func missing(_ name: String) -> Bool { (environment[name] ?? "").isEmpty }
        var names = ["VISOR_PORT", "VISOR_SESSION", "VISOR_TOKEN"].filter(missing)
        if !missing("VISOR_URL") { names.removeAll { $0 == "VISOR_PORT" } }
        guard !names.isEmpty else { return nil }
        self.names = names
    }

    /// Why Visor's MCP server can't answer, for the agent and for stderr.
    var message: String {
        "Visor's MCP server (visor-agent-host mcp) is missing \(names.joined(separator: ", ")) from its environment. "
            + "Claude Code must pass the agent's environment to its MCP servers: Visor sets these on the agent "
            + "(VISOR_PORT, VISOR_SESSION and VISOR_TOKEN) and no longer puts them in its MCP config."
    }

    /// One line from the agent answered: a request (one with an `id`) gets
    /// the error, a notification nothing.
    func answer(_ line: String, to output: any MCPOutput) {
        let id = parseJSON(line)?["id"] ?? .null
        guard !id.isNull else { return }
        output.send(.object(["jsonrpc": .string("2.0"), "id": id,
                             "error": .object(["code": .number(-32002), "message": .string(message)])]))
    }
}
