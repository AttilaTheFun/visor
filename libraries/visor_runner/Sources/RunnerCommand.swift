import Foundation

/// visor-runner-agent's commands besides running the proxy (docs/co-tenancy.md):
/// the MCP servers the proxy passes calls on to, the APNs key its push proxy
/// signs with, and the Visor servers it serves, kept in the data folder's
/// `runner.json` and the Runner's secrets. A secret header's value, and the
/// key, are read from standard input, never an argument.
public struct RunnerCommand {
    public let folder: URL
    public let secrets: RunnerSecrets
    /// The next line of standard input: a secret header's value.
    public let input: () -> String?
    public let output: (String) -> Void

    public init(folder: URL, secrets: RunnerSecrets, input: @escaping () -> String? = { readLine() },
                output: @escaping (String) -> Void = { print($0) }) {
        self.folder = folder
        self.secrets = secrets
        self.input = input
        self.output = output
    }

    public static let usage = """
        Usage: visor-runner-agent [--data <folder>] [command]

          serve    Runs the MCP proxy (the default): a call to /mcp/<name> with
                   a server's token (X-Visor-Proxy) goes on to that MCP server
                   with the secret headers kept here; a push to /apns/… goes
                   on to APNs signed with the APNs key kept here.
          status   The proxy's port, its MCP servers and the Visor servers it
                   serves (no secrets).
          endpoint set <name> <url> [--header Name=Value]… [--secret Name]…
                   An MCP server (plain HTTP, on this Mac or its network). Each
                   --secret header's value is read from standard input, a
                   line each, in order, and kept here only; --header ones are
                   given to the servers, which send them ($SESSION_ID filled in).
          endpoint remove <name>
          server add <name> --host <address>
                   A Visor server the proxy serves, given a token of its own.
                   Prints the body of the server's `PUT /api/mcp`: each MCP
                   server at this proxy (http://<address>:<port>/mcp/<name>),
                   where the server reaches this Mac, with the token.
          server push-proxy <name> --host <address>
                   Prints the body of the server's `PUT /api/push-proxy`: this
                   Runner's push proxy (http://<address>:<port>), with the
                   server's token. For a server with no APNs key of its own.
          server remove <name>
          apns set --key-id <id> --team-id <id>
                   The APNs key the push proxy signs with: the .p8's text read
                   from standard input, kept here only.
          apns remove
          port <number>
                   The proxy's port (7439), from its next start.

        The data folder is Visor's (~/Library/Application Support/Visor) unless
        given: runner.json and runner-secrets.json there.
        """

    /// Runs one command; its exit status.
    public func run(_ arguments: [String]) -> Int32 {
        var config = RunnerConfig.read(folder) ?? RunnerConfig()
        do {
            switch (arguments.first, arguments.dropFirst().first) {
            case ("status", _): status(config)
            case ("endpoint", "set"): try setEndpoint(Array(arguments.dropFirst(2)), in: &config)
            case ("endpoint", "remove"): try removeEndpoint(Array(arguments.dropFirst(2)), in: &config)
            case ("server", "add"): try addServer(Array(arguments.dropFirst(2)), in: &config)
            case ("server", "push-proxy"): try pushProxy(Array(arguments.dropFirst(2)), config: config)
            case ("server", "remove"): try removeServer(Array(arguments.dropFirst(2)), in: &config)
            case ("apns", "set"): try setAPNsKey(Array(arguments.dropFirst(2)))
            case ("apns", "remove"): removeAPNsKey()
            case ("port", _): try setPort(Array(arguments.dropFirst()), in: &config)
            case ("help", _), ("-h", _), ("--help", _): output(Self.usage)
            default: throw Problem("unknown command \(arguments.joined(separator: " "))\n\n\(Self.usage)")
            }
            return 0
        } catch let problem as Problem {
            output("visor-runner-agent: \(problem.message)")
            return 2
        } catch {
            output("visor-runner-agent: \(error.localizedDescription)")
            return 1
        }
    }

    struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func status(_ config: RunnerConfig) {
        var lines = ["MCP proxy on port \(config.mcpPort)"]
        for endpoint in config.endpoints {
            let secret = endpoint.secretHeaders.map { name in
                "\(name) (\(secrets.value(ProxyTokens.secretKey(endpoint: endpoint.name, header: name)) == nil ? "not kept" : "kept"))"
            }
            let given = endpoint.headers.keys.sorted()
            lines.append("  \(endpoint.name): \(endpoint.url)"
                + (secret.isEmpty ? "" : "; secret: " + secret.joined(separator: ", "))
                + (given.isEmpty ? "" : "; given to servers: " + given.joined(separator: ", ")))
        }
        if config.endpoints.isEmpty { lines.append("  no MCP servers") }
        lines.append(config.servers.isEmpty ? "No Visor servers." : "Visor servers: " + config.servers.joined(separator: ", "))
        if let keyID = secrets.value(APNsProxy.keyIDSecret), secrets.value(APNsProxy.keySecret) != nil {
            lines.append("Pushes: signed with APNs key \(keyID) (team \(secrets.value(APNsProxy.teamIDSecret) ?? "?"))")
        } else {
            lines.append("Pushes: no APNs key (apns set)")
        }
        output(lines.joined(separator: "\n"))
    }

    private func setEndpoint(_ arguments: [String], in config: inout RunnerConfig) throws {
        guard arguments.count >= 2 else { throw Problem("endpoint set <name> <url> [--header Name=Value]… [--secret Name]…") }
        let name = arguments[0], url = arguments[1]
        guard !name.isEmpty, !name.contains("__"), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw Problem("an MCP server's name is letters, digits, - and _, without __")
        }
        guard URLComponents(string: url)?.scheme == "http", URLComponents(string: url)?.host != nil else {
            throw Problem("\(url) is not a plain HTTP address")
        }
        var headers: [String: String] = [:], secret: [String] = []
        var rest = arguments.dropFirst(2)
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw Problem("\(flag) needs a value") }
            switch flag {
            case "--header":
                guard let equals = value.firstIndex(of: "="), equals != value.startIndex else { throw Problem("--header takes Name=Value") }
                headers[String(value[..<equals])] = String(value[value.index(after: equals)...])
            case "--secret": secret.append(value)
            default: throw Problem("unknown option \(flag)")
            }
        }
        // Each secret's value, a line of standard input, before anything is kept.
        var values: [String] = []
        for header in secret {
            guard let line = input()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                throw Problem("no value on standard input for \(header)")
            }
            values.append(line)
        }
        for old in config.endpoints.first(where: { $0.name == name })?.secretHeaders ?? [] where !secret.contains(old) {
            secrets.set(ProxyTokens.secretKey(endpoint: name, header: old), nil)
        }
        for (header, value) in zip(secret, values) { secrets.set(ProxyTokens.secretKey(endpoint: name, header: header), value) }
        config.endpoints.removeAll { $0.name == name }
        config.endpoints.append(MCPProxy.Endpoint(name: name, url: url, headers: headers, secretHeaders: secret))
        try config.write(folder)
        output("\(name): \(url)" + (secret.isEmpty ? "" : ", \(secret.count) secret header\(secret.count == 1 ? "" : "s") kept"))
    }

    private func removeEndpoint(_ arguments: [String], in config: inout RunnerConfig) throws {
        guard let name = arguments.first, let endpoint = config.endpoints.first(where: { $0.name == name }) else {
            throw Problem("no MCP server \(arguments.first ?? "")")
        }
        for header in endpoint.secretHeaders { secrets.set(ProxyTokens.secretKey(endpoint: name, header: header), nil) }
        config.endpoints.removeAll { $0.name == name }
        try config.write(folder)
        output("\(name) removed")
    }

    private func addServer(_ arguments: [String], in config: inout RunnerConfig) throws {
        guard let name = arguments.first, !name.isEmpty, !name.hasPrefix("--") else { throw Problem("server add <name> --host <address>") }
        guard arguments.count == 3, arguments[1] == "--host", !arguments[2].isEmpty else {
            throw Problem("server add <name> --host <address>: the address the server reaches this Mac at")
        }
        if !config.servers.contains(name) {
            config.servers.append(name)
            try config.write(folder)
        }
        let token = ProxyTokens.token(for: name, in: secrets)
        output(Self.serverSettings(config, host: arguments[2], token: token))
    }

    private func pushProxy(_ arguments: [String], config: RunnerConfig) throws {
        guard arguments.count == 3, arguments[1] == "--host", !arguments[2].isEmpty else {
            throw Problem("server push-proxy <name> --host <address>: the address the server reaches this Mac at")
        }
        guard config.servers.contains(arguments[0]) else { throw Problem("no Visor server \(arguments[0]) (server add it first)") }
        let body: [String: Any] = ["url": "http://\(arguments[2]):\(config.mcpPort)", "token": ProxyTokens.token(for: arguments[0], in: secrets)]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        output(String(decoding: data, as: UTF8.self))
    }

    /// The key from standard input: its lines up to the .p8's last.
    private func setAPNsKey(_ arguments: [String]) throws {
        var keyID = "", teamID = ""
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw Problem("\(flag) needs a value") }
            switch flag {
            case "--key-id": keyID = value
            case "--team-id": teamID = value
            default: throw Problem("unknown option \(flag)")
            }
        }
        guard keyID.count == 10, teamID.count == 10 else { throw Problem("apns set --key-id <id> --team-id <id>: ten characters each") }
        var lines: [String] = []
        while let line = input() {
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            if lines.last?.hasPrefix("-----END") == true { break }
        }
        let pem = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        guard pem.hasPrefix("-----BEGIN PRIVATE KEY-----"), pem.hasSuffix("-----END PRIVATE KEY-----") else {
            throw Problem("no APNs key (.p8) on standard input")
        }
        secrets.set(APNsProxy.keySecret, pem)
        secrets.set(APNsProxy.keyIDSecret, keyID)
        secrets.set(APNsProxy.teamIDSecret, teamID)
        output("APNs key \(keyID) kept: pushes are signed with it")
    }

    private func removeAPNsKey() {
        for name in [APNsProxy.keySecret, APNsProxy.keyIDSecret, APNsProxy.teamIDSecret] { secrets.set(name, nil) }
        output("APNs key removed: no pushes are proxied")
    }

    private func removeServer(_ arguments: [String], in config: inout RunnerConfig) throws {
        guard let name = arguments.first, config.servers.contains(name) else { throw Problem("no Visor server \(arguments.first ?? "")") }
        secrets.set(ProxyTokens.key(server: name), nil)
        config.servers.removeAll { $0 == name }
        try config.write(folder)
        output("\(name) removed: its token no longer gets through")
    }

    private func setPort(_ arguments: [String], in config: inout RunnerConfig) throws {
        guard let text = arguments.first, let port = Int(text), (1...65535).contains(port) else { throw Problem("port <number>") }
        config.mcpPort = port
        try config.write(folder)
        output("The MCP proxy listens on \(port) from its next start")
    }

    /// A server's `PUT /api/mcp` body: each MCP server at this proxy, with
    /// the headers servers send and the server's token (kept as a secret
    /// there, since it gets calls through).
    static func serverSettings(_ config: RunnerConfig, host: String, token: String) -> String {
        let endpoints: [[String: Any]] = config.endpoints.map { endpoint in
            let given: [[String: Any]] = endpoint.headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value, "secret": false] }
            return ["name": endpoint.name, "url": "http://\(host):\(config.mcpPort)/mcp/\(endpoint.name)",
                    "headers": given + [["name": MCPProxy.tokenHeader, "value": token, "secret": true]]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["endpoints": endpoints], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
