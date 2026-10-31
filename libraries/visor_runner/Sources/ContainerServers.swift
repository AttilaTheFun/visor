import Foundation
import Synchronization

/// The Runner's container servers (docs/co-tenancy.md): each a folder of
/// `folders` holding its `server.json`, and a container the Runner makes
/// and keeps through its container backend; its server reached only from
/// this computer, and the Runner's reverse proxy in front of it at the port
/// clients reach it at (on the LAN and VPNs as set). A container and the
/// server in it run on their own: the Runner,
/// started again, picks them up (`pickUp`), and while it runs asks after
/// each (`round`), makes again one whose network is lost (its volumes kept),
/// and gives each server the agents' sign-ins and the Runner's MCP servers
/// when they change. Its operations take time (`container` runs): call them
/// off the main thread. One at a time.
public final class ContainerServers: Sendable {
    public let folders: URL
    public let backend: any ContainerBackend
    let secrets: any RunnerSecrets
    /// The Runner's MCP proxy's port, which containers reach at their
    /// gateway.
    public let mcpPort: Int
    /// The MCP servers set in the Runner now.
    let endpoints: @Sendable () -> [MCPProxy.Endpoint]
    /// The agents' sign-ins as the Runner has them now.
    let signIns: @Sendable () -> ContainerServer.SignIns
    /// The address a server's codes lead with, by where it listens.
    let clientHost: @Sendable (ContainerServerSpec.Listen) -> String
    let log: @Sendable (String) -> Void
    /// How long a server just started is waited for.
    let patience: Duration
    /// The port the servers listen on in their containers.
    let serverPort: Int
    /// What each server was last given, by its id: given again when it
    /// changes. Forgotten when its container is made again.
    private let given = Mutex<[String: Given]>([:])
    /// One operation at a time.
    private let working = Mutex(())
    /// The Runner's reverse proxy in front of each server that runs, by its
    /// id: clients reach the server only through it.
    private let fronts = Mutex<[String: Front]>([:])

    struct Front: Sendable {
        var proxy: TCPProxy
        var port: Int
        var everywhere: Bool
    }

    struct Given: Equatable {
        var signIns: ContainerServer.SignIns
        var endpoints: [MCPProxy.Endpoint]
    }

    public init(folders: URL, backend: any ContainerBackend, secrets: any RunnerSecrets, mcpPort: Int,
                endpoints: @escaping @Sendable () -> [MCPProxy.Endpoint], signIns: @escaping @Sendable () -> ContainerServer.SignIns,
                clientHost: @escaping @Sendable (ContainerServerSpec.Listen) -> String = { HostAddresses.clientHost(lan: $0.lan, vpn: $0.vpn) },
                patience: Duration = .seconds(60), serverPort: Int = 7433, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folders = folders
        self.backend = backend
        self.secrets = secrets
        self.mcpPort = mcpPort
        self.endpoints = endpoints
        self.signIns = signIns
        self.clientHost = clientHost
        self.patience = patience
        self.serverPort = serverPort
        self.log = log
    }

    public func folder(_ id: String) -> URL { folders.appendingPathComponent(id, isDirectory: true) }

    /// The container servers there are: the folders with a `server.json`.
    public func servers() -> [ContainerServerSpec] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? ContainerServerSpec.read($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// What the Runner last found of a server.
    public func state(_ id: String) -> ContainerServerState? { ContainerServerState.read(folder(id)) }

    func server(_ spec: ContainerServerSpec) -> ContainerServer {
        var server = ContainerServer(spec: spec, backend: backend)
        server.serverPort = serverPort
        return server
    }

    // MARK: Secrets

    /// A secret of a server's: the one kept, else a new one, kept.
    func secret(_ id: String, _ name: String) -> String {
        let key = "container-server \(id) \(name)"
        if let kept = secrets.value(key), !kept.isEmpty { return kept }
        let made = (0..<4).map { _ in String(UInt32.random(in: 0...UInt32.max), radix: 36) }.joined()
        secrets.set(key, made)
        return made
    }

    func password(_ id: String) -> String { secret(id, "password") }

    func token(_ id: String) -> String { secret(id, "mcpToken") }

    /// Whether a token is one of the servers' (the MCP proxy's question).
    public func admits(_ token: String) -> Bool {
        servers().contains { secrets.value("container-server \($0.id) mcpToken") == token }
    }

    // MARK: Changes

    /// A new container server: its folder (this user's alone) and
    /// `server.json` written, then brought up. Nil, or what went wrong (said
    /// in its state too).
    public func make(_ spec: ContainerServerSpec) -> String? {
        working.withLock { _ in
            do {
                try FileManager.default.createDirectory(at: folder(spec.id), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try spec.write(folder(spec.id))
            } catch {
                return "\(error)"
            }
            return bringUp(spec)
        }
    }

    /// A stopped server started again. Nil, or what went wrong.
    public func start(_ id: String) -> String? {
        working.withLock { _ in
            guard var spec = try? ContainerServerSpec.read(folder(id)) else { return "No container server \(id)" }
            spec.stopped = false
            do { try spec.write(folder(id)) } catch { return "\(error)" }
            return bringUp(spec)
        }
    }

    /// The server stopped, and left so until started again: its container
    /// stopped, its volumes kept. Nil, or what went wrong.
    public func stop(_ id: String) -> String? {
        working.withLock { _ in
            guard var spec = try? ContainerServerSpec.read(folder(id)) else { return "No container server \(id)" }
            spec.stopped = true
            do { try spec.write(folder(id)) } catch { return "\(error)" }
            unfront(id)
            if server(spec).container()?.running == true, !server(spec).stop() { return "\(spec.containerName) didn't stop" }
            ContainerServerState(state: "stopped").write(folder(id))
            return nil
        }
    }

    /// The server's container made again from the image `server.json` names
    /// now, its volumes kept, so its sessions are as they were. Nil, or what
    /// went wrong.
    public func upgrade(_ id: String) -> String? {
        working.withLock { _ in
            guard let spec = try? ContainerServerSpec.read(folder(id)) else { return "No container server \(id)" }
            remake(spec)
            return spec.stopped ? nil : bringUp(spec)
        }
    }

    /// The server gone: its container, its volumes (and with them its
    /// sessions), its secrets and its folder.
    public func remove(_ id: String) {
        working.withLock { _ in
            unfront(id)
            if let spec = try? ContainerServerSpec.read(folder(id)) { server(spec).removeWithVolumes() }
            for name in ["password", "mcpToken"] { secrets.set("container-server \(id) \(name)", nil) }
            given.withLock { _ = $0.removeValue(forKey: id) }
            try? FileManager.default.removeItem(at: folder(id))
        }
    }

    /// The container gone, its volumes kept; what it was given forgotten.
    func remake(_ spec: ContainerServerSpec) {
        server(spec).removeContainer()
        given.withLock { _ = $0.removeValue(forKey: spec.id) }
    }

    // MARK: Keeping them up

    /// Each server not stopped brought up: its container running, its
    /// server answering, given what it should have. What went wrong, by
    /// server.
    @discardableResult
    public func pickUp() -> [String: String] {
        working.withLock { _ in
            var problems: [String: String] = [:]
            for spec in servers() where !spec.stopped {
                if let problem = bringUp(spec) { problems[spec.id] = problem }
            }
            return problems
        }
    }

    /// Each server not stopped asked after: one that doesn't answer has its
    /// network checked, and is made again (its volumes kept) where that is
    /// lost; then brought up as it should be, and what was found written.
    public func round() {
        working.withLock { _ in
            for spec in servers() where !spec.stopped {
                let server = server(spec)
                var network: ContainerServerState.Network?
                if server.container()?.running == true, !server.answering() {
                    let checked = server.networkCheck()
                    network = checked
                    if !checked.ok {
                        log("\(spec.name): its network is lost (\(checked.detail)): made again, its volumes kept")
                        remake(spec)
                    }
                }
                if let problem = bringUp(spec, network: network) { log("\(spec.name): \(problem)") }
            }
        }
    }

    /// Picked up, then asked after every `every`, until `stopped`.
    public func run(every: Duration = .seconds(30), stopped: @escaping @Sendable () -> Bool) {
        for (id, problem) in pickUp() { log("container server \(id): \(problem)") }
        while !stopped() {
            let clock = ContinuousClock(), start = clock.now
            while clock.now - start < every && !stopped() { Thread.sleep(forTimeInterval: 0.2) }
            if !stopped() { round() }
        }
        stopFronting()
    }

    /// Every server's proxy stopped (the Runner quitting): the servers run
    /// on, unreached until it is back.
    public func stopFronting() {
        for id in fronts.withLock({ Array($0.keys) }) { unfront(id) }
    }

    /// The Runner's proxy listening at the server's clients' port, as it is
    /// set now (left as it is when it already listens so). Nil, or what went
    /// wrong.
    func front(_ spec: ContainerServerSpec) -> String? {
        let everywhere = spec.listen.lan || spec.listen.vpn
        if let had = fronts.withLock({ $0[spec.id] }), had.port == spec.listen.port, had.everywhere == everywhere { return nil }
        unfront(spec.id)
        // Asked for each connection: a container made again may have another address.
        let server = server(spec)
        guard let proxy = TCPProxy(port: UInt16(spec.listen.port), everywhere: everywhere, upstream: { server.upstream() }) else {
            return "Port \(spec.listen.port) is taken"
        }
        proxy.start()
        fronts.withLock { $0[spec.id] = Front(proxy: proxy, port: spec.listen.port, everywhere: everywhere) }
        return nil
    }

    /// The server's proxy stopped: its clients reach it no more.
    func unfront(_ id: String) {
        fronts.withLock { $0.removeValue(forKey: id) }?.proxy.stop()
    }

    /// The container running, the agents' sign-ins in it, its server
    /// answering, and its MCP servers the Runner's; what was found written
    /// to its state. Nil, or what went wrong.
    @discardableResult
    func bringUp(_ spec: ContainerServerSpec, network: ContainerServerState.Network? = nil) -> String? {
        let server = server(spec)
        let address = "http://\(clientHost(spec.listen)):\(spec.listen.port)"
        var state = ContainerServerState(state: "starting")
        state.container = spec.containerName
        state.address = address
        state.network = network
        var problem = bringUp(server, address: address)
        if problem == nil { problem = front(spec) }
        if let problem {
            state.state = "failed"
            state.error = problem
        } else if let hello = server.hello(password: password(spec.id)) {
            state.state = "ready"
            state.server = .init(version: hello.version, answering: true)
            state.code = hello.code
        } else {
            state.server = .init(version: nil, answering: server.answering())
        }
        state.write(folder(spec.id))
        return problem
    }

    private func bringUp(_ server: ContainerServer, address: String) -> String? {
        let id = server.spec.id
        if let problem = server.ensureRunning() { return problem }
        let now = Given(signIns: signIns(), endpoints: endpoints())
        var had = given.withLock { $0[id] }
        if !server.answering() {
            // Its sign-ins first, so its agents start with them.
            if let problem = server.writeSignIns(now.signIns) { return problem }
            had = Given(signIns: now.signIns, endpoints: had?.endpoints ?? [])
            given.withLock { $0[id] = had }
            if let problem = server.startServer(password: password(id), clientAddress: address) { return problem }
            let clock = ContinuousClock(), start = clock.now
            while !server.answering() {
                guard clock.now - start < patience else { return "The server in \(server.name) doesn't answer" }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if had?.signIns != now.signIns {
            if let problem = server.writeSignIns(now.signIns) { return problem }
        }
        if had?.endpoints != now.endpoints {
            guard let gateway = server.gateway() else { return "\(server.name) has no route to this computer" }
            if let problem = server.setMCP(now.endpoints, proxy: "http://\(gateway):\(mcpPort)", token: token(id), password: password(id)) {
                return problem
            }
        }
        given.withLock { $0[id] = now }
        return nil
    }
}
