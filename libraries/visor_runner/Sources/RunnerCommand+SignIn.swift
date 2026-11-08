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

    /// Where a server the Runner serves is, for its signed-in clients'
    /// requests, and its password (standard input), which the Runner passes
    /// on in place of theirs.
    func setReach(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "server reach <name> --at <host>:<port> (its password on standard input)"
        guard arguments.count == 3, arguments[1] == "--at", let colon = arguments[2].lastIndex(of: ":"),
              let port = Int(arguments[2][arguments[2].index(after: colon)...]), (1...65535).contains(port),
              !arguments[2][..<colon].isEmpty else { throw Problem(usage) }
        let name = arguments[0]
        guard config.servers.contains(name) else { throw Problem("no Visor server \(name): server add it first") }
        guard let password = input(), !password.isEmpty else { throw Problem("\(usage): its password") }
        secrets.set(RunnerAPIServer.passwordSecret(name), password)
        config.reaches[name] = arguments[2]
        try config.write(folder)
        output("Signed-in clients reach \(name) at \(arguments[2]) through this Runner")
    }

    /// Where a server is reached, as runner.json and the secrets have it now.
    public static func reach(_ name: String, folder: URL, secrets: RunnerSecrets) -> RunnerAPIServer.Reach? {
        guard let address = RunnerConfig.read(folder)?.reaches[name], let colon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: colon)...]),
              let password = secrets.value(RunnerAPIServer.passwordSecret(name)) else { return nil }
        return RunnerAPIServer.Reach(host: String(address[..<colon]), port: port, password: password)
    }

    /// No user: no one signs in, and every session ends.
    func removeUser(in config: inout RunnerConfig) throws {
        if let old = config.user { RunnerSessions(secrets: secrets).endAll(of: old) }
        secrets.set(RunnerPasswordAuth.secret, nil)
        config.user = nil
        try config.write(folder)
        output("No one signs in to this Runner")
    }

    /// The port clients sign in at, and the names (`--name`) the Runner's
    /// certificate is for besides its own: an address or a name they reach
    /// it by.
    func setAPIPort(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "api port <number> [--name <address or name>]… | off"
        guard let given = arguments.first else { throw Problem(usage) }
        var names: [String] = []
        var rest = arguments.dropFirst()
        while let flag = rest.first {
            guard flag == "--name", rest.count >= 2, let name = rest.dropFirst().first, !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { throw Problem(usage) }
            names.append(name)
            rest = rest.dropFirst(2)
        }
        if given == "off" {
            guard names.isEmpty else { throw Problem(usage) }
            config.apiPort = nil
        } else {
            guard let port = Int(given), (1...65535).contains(port) else { throw Problem("\(usage): a port from 1 to 65535") }
            guard port != config.mcpPort, port != config.githubProxyPort, !config.fronts.contains(where: { $0.port == port }) else {
                throw Problem("port \(port) is taken by the MCP proxy, the GitHub proxy or a front")
            }
            config.apiPort = port
            config.apiNames = names
        }
        try config.write(folder)
        output(config.apiPort.map { "Clients sign in at port \($0) from the agent's next start, over TLS with this Runner's certificate (api certificate)" }
            ?? "No sign-in from the agent's next start")
    }

    /// The certificate clients sign in over. No arguments: the one in use,
    /// the Runner's own (made the first time: its fingerprint, which a client
    /// shows at its first sign-in for the person to compare, and the
    /// certificate) or the files named. `--file <chain> --key <key>`: those
    /// files from the agent's next start (the tailnet's, from `tailscale
    /// cert`); `--own`: the Runner's own again.
    func setOrPrintAPICertificate(_ arguments: [String], in config: inout RunnerConfig) throws {
        let usage = "api certificate [--file <chain.pem> --key <key.pem> | --own]"
        switch arguments.count {
        case 0:
            if let file = config.apiCertificateFile {
                output("From \(file) (key \(config.apiKeyFile ?? "?")), read at the agent's start")
                return
            }
            let identity = try RunnerIdentity.kept(in: secrets, names: RunnerIdentity.names(given: config.apiNames))
            output("SHA-256 \(try identity.fingerprint)\n" + (try identity.pem))
        case 1 where arguments[0] == "--own":
            config.apiCertificateFile = nil
            config.apiKeyFile = nil
            try config.write(folder)
            output("Clients sign in over this Runner's own certificate from the agent's next start")
        case 4 where arguments[0] == "--file" && arguments[2] == "--key":
            let chain = (try? String(contentsOfFile: arguments[1], encoding: .utf8)) ?? ""
            let key = (try? String(contentsOfFile: arguments[3], encoding: .utf8)) ?? ""
            guard chain.contains("-----BEGIN CERTIFICATE-----") else { throw Problem("\(arguments[1]): no certificate in it") }
            guard key.contains("PRIVATE KEY-----") else { throw Problem("\(arguments[3]): no private key in it") }
            config.apiCertificateFile = arguments[1]
            config.apiKeyFile = arguments[3]
            try config.write(folder)
            output("Clients sign in over \(arguments[1]) from the agent's next start")
        default:
            throw Problem(usage)
        }
    }
}
