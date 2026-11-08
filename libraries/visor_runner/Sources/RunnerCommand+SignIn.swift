import Foundation

// Signing in to the Runner (docs/runner-accounts.md, step 2): its one user,
// whose password is read from standard input and kept only as a hash, and
// the port its side for clients listens on.

extension RunnerCommand {
    /// The Runner's user: its name, and its password from standard input
    /// (a line, at least 12 characters), kept as a scrypt hash. Every
    /// session there was ends.
    func setUser(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "user set <name> (the password on standard input)"
        guard arguments.count == 1, let name = arguments.first, !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || "._-@".contains($0) }) else { throw Problem(usage) }
        guard let password = input(), password.count >= 12 else { throw Problem("\(usage): a password of 12 characters or more") }
        secrets.set(RunnerPasswordAuth.secret, try RunnerPassword.hash(password))
        let sessions = RunnerSessions(secrets: secrets)
        if let old = config.user { sessions.endAll(of: old) }
        sessions.endAll(of: name)
        config.user = name
        try config.write(folder)
        output("\(name) signs in to this Runner with that password; no session from before stays")
    }

    /// No user: no one signs in, and every session ends.
    func removeUser(in config: inout RunnerConfig) throws {
        if let old = config.user { RunnerSessions(secrets: secrets).endAll(of: old) }
        secrets.set(RunnerPasswordAuth.secret, nil)
        config.user = nil
        try config.write(folder)
        output("No one signs in to this Runner")
    }

    func setAPIPort(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "api port <number> | off"
        guard arguments.count == 1, let given = arguments.first else { throw Problem(usage) }
        if given == "off" {
            config.apiPort = nil
        } else {
            guard let port = Int(given), (1...65535).contains(port) else { throw Problem("\(usage): a port from 1 to 65535") }
            guard port != config.mcpPort, port != config.githubProxyPort, !config.fronts.contains(where: { $0.port == port }) else {
                throw Problem("port \(port) is taken by the MCP proxy, the GitHub proxy or a front")
            }
            config.apiPort = port
        }
        try config.write(folder)
        output(config.apiPort.map { "Clients sign in at port \($0) from the agent's next start" }
            ?? "No sign-in from the agent's next start")
    }
}
