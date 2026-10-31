import CVisorPOSIX
import Foundation

/// A container host for one container server (docs/co-tenancy.md, the
/// container host's interface): its container kept, the Visor server in it
/// started, its clients' connections passed on from a port of this
/// computer's, its agents' sign-ins given, and what it found written down.
public struct ServerHost: Sendable {
    public let server: ContainerServer
    /// This computer's address the server's codes lead with.
    public var clientHost: String

    public init(server: ContainerServer, clientHost: String? = nil) {
        self.server = server
        self.clientHost = clientHost ?? HostAddresses.clientHost(lan: server.spec.listen.lan, vpn: server.spec.listen.vpn)
    }

    public var clientAddress: String { "http://\(clientHost):\(server.spec.listen.port)" }

    /// The port of the host's MCP proxy for the container's agents: the
    /// one after the clients'.
    public var mcpPort: Int { server.spec.listen.port + 1 }

    /// The container's token for the host's MCP proxy: the one kept, else
    /// a new one, kept.
    func mcpToken() throws -> String {
        if let kept = server.secrets.value("mcpToken"), !kept.isEmpty { return kept }
        let made = (0..<4).map { _ in String(UInt32.random(in: 0...UInt32.max), radix: 36) }.joined()
        try server.secrets.set("mcpToken", made)
        return made
    }

    /// This computer's address as the container sees it: its default
    /// route's gateway (from /proc/net/route, the address in hex, its bytes
    /// in the kernel's order).
    func gateway() -> String? {
        let script = "awk '$2 == \"00000000\" { print $3; exit }' /proc/net/route"
        guard let read = server.container.run(["exec", server.spec.containerName, "sh", "-c", script]), read.status == 0,
              let value = UInt32(read.output.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
        return [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, value >> 24].map(String.init).joined(separator: ".")
    }

    /// The server's MCP servers set to the host's proxy (its `PUT
    /// /api/mcp`), each with this container's token as a secret header;
    /// the request and the password in files of the container's for the
    /// call, never on a command line. Nil, or what went wrong.
    func configureMCP() -> String? {
        guard !server.spec.mcp.isEmpty else { return nil }
        guard let gateway = gateway() else { return "The container has no route to this computer" }
        do {
            let token = try mcpToken(), password = try server.password()
            let endpoints: [[String: Any]] = server.spec.mcp.map { endpoint in
                let headers = endpoint.headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value, "secret": false] as [String: Any] }
                return ["name": endpoint.name, "url": "http://\(gateway):\(mcpPort)/mcp/\(endpoint.name)",
                        "headers": headers + [["name": MCPProxy.tokenHeader, "value": token, "secret": true]]]
            }
            let body = try JSONSerialization.data(withJSONObject: ["endpoints": endpoints])
            let folder = "/root/.visor-host/"
            guard server.put(body, at: folder + "mcp.json"), server.put(Data("Authorization: Bearer \(password)\n".utf8), at: folder + "auth") else {
                return "Could not write the MCP servers into the container"
            }
            let script = "curl -s -o /dev/null -w '%{http_code}' -X PUT -H @\(folder)auth -H 'Content-Type: application/json' "
                + "--data-binary @\(folder)mcp.json http://127.0.0.1:\(server.serverPort)/api/mcp; rm -f \(folder)auth \(folder)mcp.json"
            let answer = server.container.run(["exec", server.spec.containerName, "sh", "-c", script])
            return answer?.output.hasPrefix("200") == true ? nil : "The server didn't take its MCP servers (\(answer?.said ?? "no answer"))"
        } catch {
            return "\(error)"
        }
    }

    /// Whether the server in the container takes connections now, from here.
    public func answering() -> Bool {
        guard let address = server.address() else { return false }
        let connection = visor_connect_tcp(address, UInt16(server.serverPort))
        guard connection >= 0 else { return false }
        close(connection)
        return true
    }

    /// The server's answer to a REST call of `path`, made in the container
    /// with its password (given on standard input, never on a command
    /// line): its JSON, or nil.
    func ask(_ path: String) -> [String: Any]? {
        guard let password = try? server.password() else { return nil }
        let script = "curl -s -m 5 -H @- http://127.0.0.1:\(server.serverPort)/api/\(path)"
        guard let answer = server.container.run(["exec", "--interactive", server.spec.containerName, "sh", "-c", script],
                                                input: Data("Authorization: Bearer \(password)\n".utf8)),
              answer.status == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(answer.output.utf8))) as? [String: Any]
    }

    /// What the host finds now: the container, the server in it, where
    /// clients reach it and its code.
    public func status() -> ServerState {
        var state = ServerState(state: "starting")
        switch server.state() {
        case .missing:
            state.state = "stopped"
            state.error = "There is no container \(server.spec.containerName)"
            return state
        case .stopped:
            state.state = "stopped"
            state.container = server.spec.containerName
            return state
        case .running:
            state.container = server.spec.containerName
        }
        let answering = answering()
        let hello = answering ? ask("hello") : nil
        state.server = ServerState.Server(version: hello?["version"] as? String, answering: answering)
        state.address = clientAddress
        if answering {
            state.code = ask("code")?["text"] as? String
            state.state = "ready"
        }
        return state
    }

    /// The names `credentials` takes, and the secret each is kept as.
    static let credentialNames = ["claudeToken", "openrouterKey", "codexAuth"]

    /// `credentials`: the sign-ins and secret headers given, kept; one
    /// given as null forgotten, one left out left as it was. Says which were
    /// kept (never their values), and marks the folder so a running `serve`
    /// takes them up.
    public func credentials(_ input: Data) throws -> [String] {
        guard let given = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            throw ContainerHostError("credentials are given as a JSON object")
        }
        var kept: [String] = []
        for name in Self.credentialNames where given.keys.contains(name) {
            try server.secrets.set(name, given[name] as? String)
            kept.append(name)
        }
        if let secrets = given["mcpSecrets"] as? [String: Any] {
            for (key, value) in secrets {
                try server.secrets.set("mcp " + key, value as? String)
            }
            kept.append("mcpSecrets")
        }
        try UUID().uuidString.write(to: server.folder.appendingPathComponent("credentials.stamp"), atomically: true, encoding: .utf8)
        return kept
    }

    /// Every secret the host keeps for the server forgotten: its password,
    /// its proxy's token, the sign-ins and the secret headers.
    public func forgetSecrets() {
        let mcp = server.spec.mcp.flatMap { endpoint in endpoint.secretHeaders.map { "mcp \(endpoint.name) \($0)" } }
        for name in ["password", "mcpToken"] + Self.credentialNames + mcp {
            try? server.secrets.set(name, nil)
        }
    }

    /// The mark `credentials` leaves when it changes them.
    var credentialsStamp: String {
        (try? String(contentsOf: server.folder.appendingPathComponent("credentials.stamp"), encoding: .utf8)) ?? ""
    }

    /// The container made again from the image `server.json` names now,
    /// its disks kept; the server started in it again.
    public func upgrade() -> String? {
        server.remove(data: false)
        return bringUp()
    }

    /// The container running, the agents' sign-ins in it, and its server
    /// answering. Nil, or what went wrong.
    func bringUp(patience: Duration = .seconds(60)) -> String? {
        if let problem = server.ensureContainer() { return problem }
        if let problem = server.applyCredentials() { return problem }
        if answering() { return nil }
        do {
            if let problem = try server.startServer(clientAddress: clientAddress) { return problem }
        } catch {
            return "\(error)"
        }
        let clock = ContinuousClock(), start = clock.now
        while clock.now - start < patience {
            if answering() { return nil }
            Thread.sleep(forTimeInterval: 1)
        }
        return "The server in \(server.spec.containerName) doesn't answer"
    }

    /// `serve`: the container and its server kept up, and its clients'
    /// connections passed on, until `stopped`; each round (`every`) the
    /// server asked after, and the sign-ins given again when `credentials`
    /// changed them. Ended, it stops passing connections on and leaves the
    /// container and its server running.
    public func serve(every: Duration = .seconds(30), stopped: @escaping @Sendable () -> Bool) {
        var proxy: TCPProxy?
        var mcp: MCPProxy?
        var configured = false
        var applied = credentialsStamp
        let server = server
        while !stopped() {
            var state: ServerState
            let network = remakeIfNetworkLost()
            if network?.ok == false { configured = false }
            if let problem = bringUp() {
                state = status()
                state.state = "failed"
                state.error = problem
            } else {
                if credentialsStamp != applied {
                    applied = credentialsStamp
                    if let problem = server.applyCredentials() { log("credentials: \(problem)") }
                }
                if proxy == nil {
                    proxy = TCPProxy(port: UInt16(server.spec.listen.port), everywhere: server.spec.listen.lan || server.spec.listen.vpn) {
                        server.address().map { ($0, UInt16(server.serverPort)) }
                    }
                    proxy?.start()
                    if proxy == nil { log("port \(server.spec.listen.port) can't be had") }
                }
                if mcp == nil, !server.spec.mcp.isEmpty, let token = try? mcpToken() {
                    let secrets = server.secrets
                    mcp = MCPProxy(port: UInt16(mcpPort), token: token, endpoints: server.spec.mcp) { secrets.value("mcp \($0) \($1)") }
                    mcp?.start()
                    if mcp == nil { log("port \(mcpPort) can't be had") }
                }
                if !configured {
                    if let problem = configureMCP() { log("MCP servers: \(problem)") } else { configured = true }
                }
                state = status()
                if proxy == nil {
                    state.state = "failed"
                    state.error = "Port \(server.spec.listen.port) is taken"
                }
            }
            if let network { state.network = network }
            state.write(server.folder)
            let clock = ContinuousClock(), start = clock.now
            while clock.now - start < every && !stopped() { Thread.sleep(forTimeInterval: 0.2) }
        }
        proxy?.stop()
        mcp?.stop()
    }

    /// A running container whose server doesn't answer, asked after its
    /// network; one whose network is lost is made again (`bringUp` next),
    /// its home and Bazel's disks kept, so its sessions are as they were.
    /// What the check found, when it was made.
    func remakeIfNetworkLost(local: [HostAddresses.Address] = HostAddresses.all()) -> ServerState.Network? {
        guard server.state() == .running, !answering() else { return nil }
        let network = server.networkCheck(local: local)
        if !network.ok {
            log("its network is lost (\(network.detail)): made again, its disks kept")
            server.remove(data: false)
        }
        return network
    }

    func log(_ line: String) {
        FileHandle.standardError.write(Data("\(server.spec.containerName): \(line)\n".utf8))
    }
}
