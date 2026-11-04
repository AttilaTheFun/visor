/// Where Visor's server is, as an agent's MCP server is told it
/// (`VISOR_URL`, or this computer's own at `VISOR_PORT`): `ws://host:port`,
/// with a path or not. Only plain WebSockets: the server an agent reaches is
/// this computer's, or its container's computer on the network between them.
struct MCPURL: Equatable {
    let host: String
    let port: UInt16
    let path: String

    init?(_ text: String) {
        guard text.hasPrefix("ws://") else { return nil }
        let rest = text.dropFirst("ws://".count)
        let slash = rest.firstIndex(of: "/")
        let authority = slash.map { rest[..<$0] } ?? rest
        path = slash.map { String(rest[$0...]) } ?? "/"
        var host: Substring
        var port: Substring?
        if authority.hasPrefix("[") {
            // An IPv6 address, in brackets, its port after them.
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") { port = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            port = authority[authority.index(after: colon)...]
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }
        self.host = String(host)
        if let port {
            guard let number = UInt16(port), number > 0 else { return nil }
            self.port = number
        } else {
            self.port = 80
        }
    }

    /// The `Host` header: the host as given, and the port.
    var hostHeader: String {
        (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }
}
