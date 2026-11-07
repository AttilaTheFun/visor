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

    func printGitHubProxyCA() throws {
        output(try RunnerCA.kept(in: secrets).pem)
    }
}
