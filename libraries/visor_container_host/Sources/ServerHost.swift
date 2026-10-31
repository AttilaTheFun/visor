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
        var applied = credentialsStamp
        let server = server
        while !stopped() {
            var state: ServerState
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
                state = status()
                if proxy == nil {
                    state.state = "failed"
                    state.error = "Port \(server.spec.listen.port) is taken"
                }
            }
            state.write(server.folder)
            let clock = ContinuousClock(), start = clock.now
            while clock.now - start < every && !stopped() { Thread.sleep(forTimeInterval: 0.2) }
        }
        proxy?.stop()
    }

    func log(_ line: String) {
        FileHandle.standardError.write(Data("\(server.spec.containerName): \(line)\n".utf8))
    }
}
