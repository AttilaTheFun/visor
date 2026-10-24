// The machines sessions lease from this server's oss (OS Server,
// AttilaTheFun/oss): macOS, Linux and Windows VMs, iOS simulators, Android
// emulators. A session asks this server — the `visor` command in it
// (ContainerTools), natively or in a container — and this server asks oss
// in the session's name, with oss's token, which the session never holds.
// What each session holds is kept up with, and shown with it
// (SessionInfo.leases).
//
//     GET    /machines?session=<id>                   the session's leases
//     GET    /machines/status                          what oss has, and how much is leased
//     POST   /machines            {session, platform, config?, minutes?, wait?, key?}
//     GET    /machines/<id>?session=<id>               one of them
//     POST   /machines/<id>/renew {session, minutes?}
//     DELETE /machines/<id>?session=<id>
//     GET    /machines/<id>/screenshot?session=<id>   {png: base64}
//     POST   /machines/<id>/command {session, arguments}   simctl or adb, as oss runs it
//     POST   /machines/<id>/upload  {session, name, data: base64}
//
// SSH, VNC and adb reach the lease at oss's own address, on the ports oss
// forwards for it (in each lease's answer).

import Foundation
import OSSClient
import VisorProtocol

extension VisorServer {
    /// The oss server sessions lease machines from, when one is set (at an
    /// address that is a URL) and its token kept.
    var ossClient: OSSClient? {
        guard !settings.ossServer.trimmingCharacters(in: .whitespaces).isEmpty, ossTokenKept else { return nil }
        return OSSAccess.client(server: settings.ossServer)
    }

    /// Whether oss's token is kept.
    public var ossTokenKept: Bool { !(Self.secrets.get("ossToken") ?? "").isEmpty }

    /// Keeps oss's token (with the server's secrets); nil or empty lets it go.
    public func setOSSToken(_ token: String?) {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Self.secrets.set("ossToken", token.isEmpty ? nil : token)
    }

    /// `GET /oss`: the oss server sessions lease from, and whether its
    /// token is kept (never the token).
    func restOSS(_ call: RESTCall) -> HTTPResponse {
        .json(JSONValue.object(["server": .string(settings.ossServer), "tokenKept": .bool(ossTokenKept)]).encoded())
    }

    /// `POST /oss {server, token}`: sets the oss server and keeps its token,
    /// as Settings › Machines does (the server keeps it with its own
    /// secrets, which it reads without asking); an empty server takes it
    /// off. What each session leases is asked again.
    func restSetOSS(_ call: RESTCall) -> HTTPResponse {
        let body = parseJSON(call.request.body) ?? .object([:])
        if let server = body["server"].string {
            settings.ossServer = server.trimmingCharacters(in: .whitespaces)
            if settings.ossServer.isEmpty { setOSSToken(nil) }
        }
        if let token = body["token"].string { setOSSToken(token) }
        Task { await refreshLeases() }
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

    /// Asks oss what this server's sessions lease, and tells the clients of
    /// each session whose leases changed.
    func refreshLeases() async {
        guard let oss = ossClient, let all = try? await oss.leases() else {
            if !leases.isEmpty { showLeases([:]) }
            return
        }
        var held: [String: [SessionLease]] = [:]
        for lease in all where lease.holder.hasPrefix("visor:") {
            let session = String(lease.holder.dropFirst("visor:".count))
            held[session, default: []].append(Self.sessionLease(lease))
        }
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
        guard let oss = ossClient else {
            return respond(Self.machinesError(503, "This computer's Visor server has no oss server to lease machines from (Visor Server's settings, or `visor-server oss <url> <token file>`)."))
        }
        let sessionID = query["session"] ?? body["session"].string ?? ""
        let record = session(sessionID)
        if parts == ["machines", "status"], request.method == "GET" {
            Task { respond(await Self.machinesStatus(oss)) }
            return
        }
        guard let record else { return respond(Self.machinesError(404, "No such session here: \(sessionID.isEmpty ? "(none given)" : sessionID).")) }
        let holder = Self.leaseHolder(session: record.info.id)
        let inContainer = record.info.container != nil
        Task {
            let answer: HTTPResponse
            do {
                answer = try await machines(oss, request.method, Array(parts.dropFirst()), body: body, holder: holder, inContainer: inContainer)
            } catch let error as OSSError {
                answer = Self.machinesError(error.status == 0 ? 502 : error.status, "oss: \(error.message)")
            } catch {
                answer = Self.machinesError(502, error.localizedDescription)
            }
            respond(answer)
            await refreshLeases()
        }
    }

    private func machines(_ oss: OSSClient, _ method: String, _ parts: [String], body: JSONValue, holder: String,
                          inContainer: Bool) async throws -> HTTPResponse {
        let name = oss.host
        let resolve = ServerPlatform.current.host.resolve
        let lan = ServerPlatform.current.host.networkAddresses().first { $0.kind == .lan }?.address
        let host = await Task.detached { Self.leaseHost(oss: name, inContainer: inContainer, lan: lan, resolve: resolve) }.value
        switch (method, parts.count, parts.last) {
        case ("GET", 0, _):
            let held = try await oss.leases().filter { $0.holder == holder }
            return .json(JSONValue.object(["leases": .array(held.map { Self.leaseJSON($0, host: host) })]).encoded())
        case ("POST", 0, _):
            guard let platform = body["platform"].string.flatMap(Platform.init(rawValue:)) else {
                return Self.machinesError(400, "Which machine? One of: \(Platform.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let request = LeaseRequest(platform: platform, config: body["config"].string, minutes: body["minutes"].int, holder: holder,
                                       sshPublicKey: body["key"].string)
            var leasing = oss
            leasing.timeout = 900
            let lease = try await leasing.lease(request, waitForCapacity: body["wait"].bool ?? false)
            return .json(Self.leaseJSON(lease, host: host).encoded())
        default:
            break
        }
        // One lease: this session's, or none of its business.
        guard let id = parts.first else { return Self.machinesError(404, "No such machine.") }
        let lease = try await oss.lease(id)
        guard lease.holder == holder else { return Self.machinesError(404, "This session holds no machine \(id).") }
        switch (method, parts.count, parts.count > 1 ? parts[1] : nil) {
        case ("GET", 1, _):
            return .json(Self.leaseJSON(lease, host: host).encoded())
        case ("DELETE", 1, _):
            try await oss.release(id)
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

    /// What oss has: its bases, and how many of each kind are leased.
    private static func machinesStatus(_ oss: OSSClient) async -> HTTPResponse {
        do {
            let status = try await oss.status()
            let capacity: [JSONValue] = status.capacity.map {
                .object(["platform": .string($0.platform.rawValue), "limit": .number(Double($0.limit)), "leased": .number(Double($0.leased))])
            }
            let bases: [JSONValue] = status.bases.map { .object(["platform": .string($0.platform.rawValue), "config": .string($0.config)]) }
            return .json(JSONValue.object(["server": .string(oss.server.absoluteString), "capacity": .array(capacity), "bases": .array(bases)]).encoded())
        } catch {
            return machinesError(502, "oss: \(error.localizedDescription)")
        }
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
