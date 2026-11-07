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

    /// Where the proxy's tokens come from: Keymaster's address, the App, and
    /// (from standard input) the proxy's own client key.
    func setGitHubProxyKeymaster(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "github-proxy keymaster <url> --app <github app> (the client key on standard input)"
        guard arguments.count == 3, arguments[1] == "--app", let url = URL(string: arguments[0]), url.scheme == "http" || url.scheme == "https",
              !arguments[2].isEmpty else { throw Problem(usage) }
        guard let key = input()?.trimmingCharacters(in: .whitespacesAndNewlines), key.hasPrefix("km_") else {
            throw Problem("\(usage): the key is Keymaster's, km_…")
        }
        secrets.set(Self.keymasterKeySecret, key)
        config.keymasterURL = arguments[0]
        config.githubApp = arguments[2]
        try config.write(folder)
        output("The GitHub proxy asks \(arguments[0]) for \(arguments[2])'s tokens from the agent's next start")
    }

    /// Where the proxy's Keymaster key is kept with the Runner's secrets.
    public static let keymasterKeySecret = "github-proxy keymaster key"

    func printGitHubProxyCA() throws {
        output(try RunnerCA.kept(in: secrets).pem)
    }
}
