import Foundation

// The GitHub proxy's commands (docs/github-proxy.md): its port, and the
// certificate of its own authority for the agents' systems to trust.

extension RunnerCommand {
    func setGitHubProxyPort(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "github-proxy port <number> | off"
        guard arguments.count == 1, let given = arguments.first else { throw Problem(usage) }
        if given == "off" {
            config.githubProxyPort = nil
        } else {
            guard let port = Int(given), (1...65535).contains(port) else { throw Problem("\(usage): a port from 1 to 65535") }
            guard port != config.mcpPort, !config.fronts.contains(where: { $0.port == port }) else {
                throw Problem("port \(port) is taken by the MCP proxy or a front")
            }
            config.githubProxyPort = port
        }
        try config.write(folder)
        output(config.githubProxyPort.map { "The GitHub proxy listens on \($0) from the agent's next start" }
            ?? "No GitHub proxy from the agent's next start")
    }

    /// The App whose tokens the proxy uses: its id, its installation, and
    /// (from standard input, to its end) its private key, kept with the
    /// Runner's secrets only.
    func setGitHubProxyApp(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "github-proxy app --app-id <id> --installation <id> (the App's private key on standard input)"
        guard arguments.count == 4, arguments[0] == "--app-id", arguments[2] == "--installation",
              arguments[1].allSatisfy(\.isNumber), arguments[3].allSatisfy(\.isNumber), !arguments[1].isEmpty, !arguments[3].isEmpty else {
            throw Problem(usage)
        }
        var lines: [String] = []
        while let line = input() { lines.append(line) }
        let key = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard key.contains("-----BEGIN") && key.contains("PRIVATE KEY-----"), (try? GitHubAppTokens.jwt(appID: arguments[1], pem: key, now: Date())) != nil else {
            throw Problem("\(usage): the key is the App's .pem, as GitHub gave it")
        }
        secrets.set(Self.githubAppKeySecret, key)
        config.githubAppID = arguments[1]
        config.githubInstallation = arguments[3]
        try config.write(folder)
        output("The GitHub proxy uses App \(arguments[1])'s installation \(arguments[3]) from the agent's next start")
    }

    /// The body of a server's `PUT /api/github-proxy`: this Runner's proxy as
    /// the server reaches it, the server's token, the proxy's authority, and
    /// the sessions it is on for (one first, then `*`).
    func githubProxyBody(_ arguments: [String], config: RunnerConfig) throws {
        let usage = "github-proxy server <name> --host <address> --sessions <id,id…|*>"
        guard arguments.count == 5, arguments[1] == "--host", !arguments[2].isEmpty, arguments[3] == "--sessions", !arguments[4].isEmpty else {
            throw Problem(usage)
        }
        guard config.servers.contains(arguments[0]) else { throw Problem("no Visor server \(arguments[0]) (server add it first)") }
        guard let port = config.githubProxyPort else { throw Problem("no GitHub proxy (github-proxy port <number>)") }
        let body: [String: Any] = ["url": "http://\(arguments[2]):\(port)", "token": ProxyTokens.token(for: arguments[0], in: secrets),
                                   "authority": try RunnerCA.kept(in: secrets).pem,
                                   "sessions": arguments[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        output(String(decoding: data, as: UTF8.self))
    }

    /// Where the App's private key is kept with the Runner's secrets.
    public static let githubAppKeySecret = "github-proxy app key"

    func printGitHubProxyCA() throws {
        output(try RunnerCA.kept(in: secrets).pem)
    }
}
