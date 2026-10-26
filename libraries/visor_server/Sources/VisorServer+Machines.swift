// The machines sessions lease from this server's oss servers (OS Server,
// AttilaTheFun/oss): macOS, Linux and Windows VMs, iOS simulators, Android
// emulators, each from the nearest server with room for it (OSSPool). A
// session asks this server — the `visor` command in it (ContainerTools),
// natively or in a container — and this server asks oss in the session's
// name, with each server's token, which the session never holds. What each
// session holds is kept up with, and shown with it (SessionInfo.leases).
//
//     GET    /oss                                      the servers, and whether each one's token is kept
//     POST   /oss                 {server, token?, remove?}   one added (or its token kept), or taken off
//     GET    /machines?session=<id>                   the session's leases
//     GET    /machines/status                          what each server has, and how much is leased
//     POST   /machines            {session, platform, config?, minutes?, wait?, key?, server?}
//     GET    /machines/<id>?session=<id>               one of them
//     POST   /machines/<id>/renew {session, minutes?}
//     DELETE /machines/<id>?session=<id>
//     GET    /machines/<id>/screenshot?session=<id>   {png: base64}
//     POST   /machines/<id>/command {session, arguments}   simctl or adb, as oss runs it
//     POST   /machines/<id>/upload  {session, name, data: base64}
//
// SSH, VNC and adb reach the lease at its server's own address, on the
// ports that server forwards for it (in each lease's answer).

import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// The oss servers set, as kept.
    public var ossServers: [String] { settings.ossServers.map(OSSAccess.normalized).filter { !$0.isEmpty } }

    /// A client of each server set whose token is kept.
    var ossClients: [OSSClient] { ossServers.filter(ossTokenKept).compactMap(OSSAccess.client(server:)) }

    /// The servers set whose token is kept, leased from as one; nil for none.
    var ossPool: OSSPool? {
        let servers = ossServers.filter(ossTokenKept)
        return servers.isEmpty ? nil : OSSAccess.pool(servers: servers)
    }

    /// Where `server`'s token is kept with the server's secrets.
    public nonisolated static func ossTokenKey(_ server: String) -> String { OSSAccess.tokenKey(server) }

    /// `server` as kept: no trailing slash.
    public nonisolated static func ossAddress(_ server: String) -> String { OSSAccess.normalized(server) }

    /// Whether `server`'s token is kept.
    public func ossTokenKept(_ server: String) -> Bool { !OSSAccess.token(OSSAccess.tokenKey(server)).isEmpty }

    /// Adds `server` (where it is not set yet), and keeps its token when
    /// one is given; what each session leases is asked again.
    public func setOSSServer(_ server: String, token: String? = nil) {
        let address = OSSAccess.normalized(server)
        guard OSSAccess.url(address) != nil else { return }
        if !ossServers.contains(address) { settings.ossServers.append(address) }
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Self.secrets.set(OSSAccess.tokenKey(address), token)
        }
        Task {
            await refreshLeases()
            await checkContainers()
        }
    }

    /// Takes `server` off, and its token.
    public func removeOSSServer(_ server: String) {
        let address = OSSAccess.normalized(server)
        settings.ossServers.removeAll { OSSAccess.normalized($0) == address }
        Self.secrets.set(OSSAccess.tokenKey(address), nil)
        Task {
            await refreshLeases()
            await checkContainers()
        }
    }

    /// The token kept from before several servers, taken over as the first
    /// server's.
    func adoptOSSToken() {
        if let first = ossServers.first { OSSAccess.adoptSingleToken(for: first) }
    }

    /// `GET /oss`: the servers sessions lease from, and whether each one's
    /// token is kept (never a token).
    func restOSS(_ call: RESTCall) -> HTTPResponse {
        let servers: [JSONValue] = ossServers.map { .object(["server": .string($0), "tokenKept": .bool(ossTokenKept($0))]) }
        return .json(JSONValue.object(["servers": .array(servers)]).encoded())
    }

    /// `POST /oss {server, token?, remove?}`: adds a server and keeps its
    /// token, as Settings › Machines does (the server keeps it with its own
    /// secrets, which it reads without asking), or takes it off; an empty
    /// server takes them all off.
    func restSetOSS(_ call: RESTCall) -> HTTPResponse {
        let body = parseJSON(call.request.body) ?? .object([:])
        let server = body["server"].string.map(OSSAccess.normalized) ?? ""
        if server.isEmpty, body["server"].string != nil {
            for each in ossServers { removeOSSServer(each) }
        } else if body["remove"].bool == true {
            removeOSSServer(server)
        } else if OSSAccess.url(server) != nil {
            setOSSServer(server, token: body["token"].string)
        } else if !server.isEmpty {
            return Self.machinesError(400, "\(server) is not an address (http://host:7480).")
        }
        return restOSS(call)
    }

    /// Who holds a session's leases, as oss is told.
    static func leaseHolder(session: String) -> String { "visor:" + session }

    /// How often what the sessions lease is asked again.
    static let leaseInterval: Duration = .seconds(30)

    /// Keeps up with what each session leases, while the server runs.
    func watchLeases() {
        Task { [weak self] in
            while let self {
                await self.refreshLeases()
                try? await Task.sleep(for: Self.leaseInterval)
            }
        }
    }

    /// Asks each server what this server's sessions lease, and tells the
    /// clients of each session whose leases changed. A server that does
    /// not answer keeps what it lent as last known.
    func refreshLeases() async {
        let clients = ossClients
        var held: [String: [SessionLease]] = [:]
        var lenders: [String: OSSClient] = [:]
        var silent = Set(clients.map(\.server))
        for client in clients {
            guard let all = try? await client.leases() else { continue }
            silent.remove(client.server)
            for lease in all where lease.holder.hasPrefix("visor:") {
                lenders[lease.id] = client
                // A container is shown as the session's own, not as a machine.
                guard lease.platform != .container else { continue }
                held[String(lease.holder.dropFirst("visor:".count)), default: []].append(Self.sessionLease(lease))
            }
        }
        for (id, client) in leaseClients where silent.contains(client.server) {
            lenders[id] = client
            for (session, kept) in leases { held[session, default: []] += kept.filter { $0.id == id } }
        }
        leaseClients = lenders
        showLeases(held)
    }

    private func showLeases(_ held: [String: [SessionLease]]) {
        leases = held
        var changed = false
        for record in sessions {
            let now = (held[record.info.id] ?? []).sorted { $0.id < $1.id }
            guard now != record.info.leases else { continue }
            record.info.leases = now
            changed = true
        }
        if changed { broadcastSessions() }
    }

    static func sessionLease(_ lease: Lease) -> SessionLease {
        SessionLease(id: lease.id, platform: lease.platform.rawValue, config: lease.config, state: lease.state.rawValue,
                     expires: lease.expires.timeIntervalSince1970)
    }

    /// A request to `/machines…`, answered once oss has.
    func answerMachines(_ request: HTTPRequest, parts: [String], respond: @escaping (HTTPResponse) -> Void) {
        let query = Self.query(request.path)
        let body = parseJSON(request.body) ?? .object([:])
        guard let pool = ossPool else {
            return respond(Self.machinesError(503, "This computer's Visor server has no oss server to lease machines from (Visor Server's settings, or `visor-server oss <url> <token file>`)."))
        }
        let sessionID = query["session"] ?? body["session"].string ?? ""
        let record = session(sessionID)
        if parts == ["machines", "status"], request.method == "GET" {
            Task { respond(await Self.machinesStatus(pool)) }
            return
        }
        guard let record else { return respond(Self.machinesError(404, "No such session here: \(sessionID.isEmpty ? "(none given)" : sessionID).")) }
        let holder = Self.leaseHolder(session: record.info.id)
        let inContainer = record.info.container != nil
        Task {
            let answer: HTTPResponse
            do {
                answer = try await machines(pool, request.method, Array(parts.dropFirst()), body: body, holder: holder, inContainer: inContainer)
            } catch let error as OSSError {
                answer = Self.machinesError(error.status == 0 ? 502 : error.status, "oss: \(error.message)")
            } catch {
                answer = Self.machinesError(502, error.localizedDescription)
            }
            respond(answer)
            await refreshLeases()
        }
    }

    /// Whether the oss at `host` is the one `name` names: its host, or a
    /// part of it ("macbook" for a MacBook's .local or MagicDNS name).
    nonisolated static func ossServer(_ host: String, isNamed name: String) -> Bool {
        host.lowercased().contains(name.lowercased())
    }

    /// Where a session reaches the leases of the server `oss` answers for.
    private func leaseHost(_ oss: OSSClient, inContainer: Bool) async -> String {
        let name = oss.host
        let resolve = ServerPlatform.current.host.resolve
        let lan = ServerPlatform.current.host.networkAddresses().first { $0.kind == .lan }?.address
        return await Task.detached { Self.leaseHost(oss: name, inContainer: inContainer, lan: lan, resolve: resolve) }.value
    }

    /// The server that lent `id`, as last known, else whichever says it has it.
    func lender(of id: String) async -> OSSClient? {
        if let known = leaseClients[id] { return known }
        for client in ossClients where (try? await client.lease(id)) != nil {
            leaseClients[id] = client
            return client
        }
        return nil
    }

    private func machines(_ pool: OSSPool, _ method: String, _ parts: [String], body: JSONValue, holder: String,
                          inContainer: Bool) async throws -> HTTPResponse {
        switch (method, parts.count) {
        case ("GET", 0):
            var held: [JSONValue] = []
            for client in ossClients {
                guard let all = try? await client.leases() else { continue }
                let host = await leaseHost(client, inContainer: inContainer)
                held += all.filter { $0.holder == holder && $0.platform != .container }.map { Self.leaseJSON($0, host: host) }
            }
            return .json(JSONValue.object(["leases": .array(held)]).encoded())
        case ("POST", 0):
            let machines = Platform.allCases.filter { $0 != .container }
            guard let platform = body["platform"].string.flatMap(Platform.init(rawValue:)), platform != .container else {
                return Self.machinesError(400, "Which machine? One of: \(machines.map(\.rawValue).joined(separator: ", ")).")
            }
            let request = LeaseRequest(platform: platform, config: body["config"].string, minutes: body["minutes"].int, holder: holder,
                                       sshPublicKey: body["key"].string)
            let wait = body["wait"].bool ?? false
            let client: OSSClient
            let lease: Lease
            if let named = body["server"].string?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
                // The one it names, whatever is nearer.
                let reached = await pool.reach()
                let matching = reached.filter { Self.ossServer($0.client.host, isNamed: named) }
                guard matching.count == 1, let server = matching.first else {
                    let names = reached.map(\.client.host).joined(separator: ", ")
                    return Self.machinesError(404, matching.isEmpty ? "No oss server here is named \(named) (they are: \(names))."
                                                                    : "More than one oss server is named \(named): \(names).")
                }
                (client, lease) = (server.client, try await server.client.lease(request, waitForCapacity: wait))
            } else {
                (client, lease) = try await pool.lease(request, waitForCapacity: wait)
            }
            leaseClients[lease.id] = client
            return .json(Self.leaseJSON(lease, host: await leaseHost(client, inContainer: inContainer)).encoded())
        default:
            break
        }
        // One lease: this session's, or none of its business.
        guard let id = parts.first, let oss = await lender(of: id) else { return Self.machinesError(404, "No such machine.") }
        let lease = try await oss.lease(id)
        guard lease.holder == holder, lease.platform != .container else { return Self.machinesError(404, "This session holds no machine \(id).") }
        let host = await leaseHost(oss, inContainer: inContainer)
        switch (method, parts.count, parts.count > 1 ? parts[1] : nil) {
        case ("GET", 1, _):
            return .json(Self.leaseJSON(lease, host: host).encoded())
        case ("DELETE", 1, _):
            try await oss.release(id)
            leaseClients[id] = nil
            return .json(JSONValue.object(["released": .string(id)]).encoded())
        case ("POST", 2, "renew"?):
            return .json(Self.leaseJSON(try await oss.renew(id, minutes: body["minutes"].int), host: host).encoded())
        case ("GET", 2, "screenshot"?):
            let png = try await oss.screenshot(id)
            return .json(JSONValue.object(["png": .string(png.base64EncodedString())]).encoded())
        case ("POST", 2, "command"?):
            let arguments = body["arguments"].array?.compactMap(\.string) ?? []
            let result = try await oss.deviceCommand(lease, arguments)
            return .json(JSONValue.object(["status": .number(Double(result.status)), "output": .string(result.output),
                                           "error": .string(result.error)]).encoded())
        case ("POST", 2, "upload"?):
            guard let name = body["name"].string, !name.isEmpty, let data = body["data"].string.flatMap({ Data(base64Encoded: $0) }) else {
                return Self.machinesError(400, "A file's name and its data (base64) are needed.")
            }
            var uploading = oss
            uploading.timeout = 900
            try await uploading.upload(id, name: name, data: data)
            return .json(JSONValue.object(["uploaded": .string(name)]).encoded())
        default:
            return Self.machinesError(404, "No such request.")
        }
    }

    /// Where a session reaches a lease's ports (oss's own address, where it
    /// forwards them): as an address, since a container resolves no
    /// `.local` names; and, for a session in a container, this computer's
    /// LAN address in place of a loopback one (oss on this computer, which
    /// forwards on every address), loopback there being the container's own.
    nonisolated static func leaseHost(oss: String, inContainer: Bool, lan: String?, resolve: (String) -> String?) -> String {
        let loopback = oss == "localhost" || oss == "::1" || oss.hasPrefix("127.")
        if loopback { return inContainer ? (lan ?? oss) : oss }
        return resolve(oss) ?? oss
    }

    /// What each server that answers has, nearest first: its bases, and
    /// how many of each kind are leased.
    private static func machinesStatus(_ pool: OSSPool) async -> HTTPResponse {
        let reached = await pool.reach()
        guard !reached.isEmpty else { return machinesError(502, "oss: no server answered") }
        let servers: [JSONValue] = reached.map { server in
            let capacity: [JSONValue] = server.status.capacity.map {
                .object(["platform": .string($0.platform.rawValue), "limit": .number(Double($0.limit)), "leased": .number(Double($0.leased))])
            }
            let bases: [JSONValue] = server.status.bases.map { .object(["platform": .string($0.platform.rawValue), "config": .string($0.config)]) }
            return .object(["name": .string(server.name), "server": .string(server.client.server.absoluteString),
                            "distance": .string(server.distance.description), "capacity": .array(capacity), "bases": .array(bases)])
        }
        return .json(JSONValue.object(["servers": .array(servers)]).encoded())
    }

    /// A lease as a session is told it: with where to reach it (oss's own
    /// address, and the ports it forwards for the lease).
    static func leaseJSON(_ lease: Lease, host: String) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(lease.id), "platform": .string(lease.platform.rawValue), "config": .string(lease.config),
                                      "name": .string(lease.name), "state": .string(lease.state.rawValue),
                                      "expires": .number(lease.expires.timeIntervalSince1970), "host": .string(host)]
        if let error = lease.error { o["error"] = .string(error) }
        if let port = lease.sshPort { o["sshPort"] = .number(Double(port)) }
        if let user = lease.sshUser { o["sshUser"] = .string(user) }
        if let port = lease.vncPort { o["vncPort"] = .number(Double(port)) }
        if let password = lease.vncPassword { o["vncPassword"] = .string(password) }
        if let port = lease.adbPort { o["adbPort"] = .number(Double(port)) }
        if let udid = lease.udid { o["udid"] = .string(udid) }
        return .object(o)
    }

    static func machinesError(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status, Envelope.error(message).encoded())
    }
}
