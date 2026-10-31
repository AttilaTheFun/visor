import Foundation
import Synchronization

/// The Runner's container servers (docs/co-tenancy.md): each a folder of
/// `folders` holding its `server.json`, and a container the Runner makes
/// and keeps through its container backend; its server reached only from
/// this computer, and the Runner's reverse proxy in front of it at the port
/// clients reach it at (on the LAN and VPNs as set). The menu bar app writes
/// what should be (ContainerServerFolders); the Runner's agent
/// makes it so (`reconcile`: the first time, picking up the containers that
/// ran on while it was gone), asks after each server (`round`), makes again
/// one whose network is lost (its volumes kept), and gives each server the
/// agents' sign-ins and the Runner's MCP servers when they change. Its work
/// takes time (containers made, commands run in them): call it off the main
/// thread. One operation at a time.
public final class ContainerServers: Sendable {
    /// What the folders say.
    public let place: ContainerServerFolders
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
    /// Each server as it was last made so, by its id: one whose folder says
    /// otherwise now is made so again.
    private let applied = Mutex<[String: ContainerServerSpec]>([:])
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
        place = ContainerServerFolders(folders: folders)
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

    public func folder(_ id: String) -> URL { place.folder(id) }

    /// The container servers there are.
    public func servers() -> [ContainerServerSpec] { place.servers() }

    /// What the Runner last found of a server.
    public func state(_ id: String) -> ContainerServerState? { place.state(id) }

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

    // MARK: Making it so (the Runner's agent)

    /// Every server made as its folder says, where that has changed since
    /// it was last made so (and every one, the first time: picked up when
    /// the agent starts): one marked to be removed, removed; one marked to
    /// be upgraded, made again; a stopped one, stopped; any other, brought
    /// up. A server whose folder is gone is no longer fronted. What went
    /// wrong, by server.
    @discardableResult
    public func reconcile() -> [String: String] {
        working.withLock { _ in
            var problems: [String: String] = [:]
            let specs = servers()
            for spec in specs {
                if let problem = reconcile(spec) { problems[spec.id] = problem }
            }
            let ids = Set(specs.map(\.id))
            for id in applied.withLock({ $0.keys.filter { !ids.contains($0) } }) {
                unfront(id)
                applied.withLock { _ = $0.removeValue(forKey: id) }
            }
            return problems
        }
    }

    private func reconcile(_ spec: ContainerServerSpec) -> String? {
        let id = spec.id
        if place.marked(id, ContainerServerFolders.removeMark) {
            unfront(id)
            server(spec).removeWithVolumes()
            for name in ["password", "mcpToken"] { secrets.set("container-server \(id) \(name)", nil) }
            given.withLock { _ = $0.removeValue(forKey: id) }
            applied.withLock { _ = $0.removeValue(forKey: id) }
            try? FileManager.default.removeItem(at: folder(id))
            return nil
        }
        if place.marked(id, ContainerServerFolders.upgradeMark) {
            remake(spec)
            place.unmark(id, ContainerServerFolders.upgradeMark)
            applied.withLock { _ = $0.removeValue(forKey: id) }
        }
        guard applied.withLock({ $0[id] }) != spec else { return nil }
        let problem: String?
        if spec.stopped {
            unfront(id)
            problem = server(spec).container()?.running == true && !server(spec).stop() ? "\(spec.containerName) didn't stop" : nil
            ContainerServerState(state: "stopped").write(folder(id))
        } else {
            problem = bringUp(spec)
        }
        applied.withLock { $0[id] = spec }
        return problem
    }

    /// The container gone, its volumes kept; what it was given forgotten.
    func remake(_ spec: ContainerServerSpec) {
        server(spec).removeContainer()
        given.withLock { _ = $0.removeValue(forKey: spec.id) }
    }

    /// Each server running asked after: one that doesn't answer has its
    /// network checked, and is made again (its volumes kept) where that is
    /// lost; then brought up as it should be (given again what changed), and
    /// what was found written.
    public func round() {
        working.withLock { _ in
            for spec in servers() where !spec.stopped && !place.marked(spec.id, ContainerServerFolders.removeMark) {
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
                applied.withLock { $0[spec.id] = spec }
            }
        }
    }

    /// The Runner's agent's work until `stopped`: what the folders say made
    /// so every `poll`, every server asked after every `every`; then its
    /// proxies stopped, the servers left running.
    public func run(poll: Duration = .seconds(2), every: Duration = .seconds(30), stopped: @escaping @Sendable () -> Bool) {
        let clock = ContinuousClock()
        var asked = clock.now
        while !stopped() {
            for (id, problem) in reconcile() { log("container server \(id): \(problem)") }
            if clock.now - asked >= every {
                round()
                asked = clock.now
            }
            let start = clock.now
            while clock.now - start < poll && !stopped() { Thread.sleep(forTimeInterval: 0.1) }
        }
        stopFronting()
    }

    // MARK: Changes, made so at once (one process: the tests, a probe)

    /// A new container server, made so. Nil, or what went wrong.
    public func make(_ spec: ContainerServerSpec) -> String? {
        if let problem = place.want(spec) { return problem }
        return reconcile()[spec.id]
    }

    /// A stopped server started again. Nil, or what went wrong.
    public func start(_ id: String) -> String? { setStopped(id, false) }

    /// The server stopped, its volumes kept. Nil, or what went wrong.
    public func stop(_ id: String) -> String? { setStopped(id, true) }

    private func setStopped(_ id: String, _ stopped: Bool) -> String? {
        guard var spec = try? ContainerServerSpec.read(folder(id)) else { return "No container server \(id)" }
        spec.stopped = stopped
        if let problem = place.want(spec) { return problem }
        return reconcile()[id]
    }

    /// The server made again from its image, its volumes kept. Nil, or what
    /// went wrong.
    public func upgrade(_ id: String) -> String? {
        if let problem = place.wantUpgrade(id) { return problem }
        return reconcile()[id]
    }

    /// The server gone, and everything of it.
    public func remove(_ id: String) {
        guard place.wantRemoved(id) == nil else { return }
        reconcile()
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
