import Foundation
import OSSClient
import Synchronization

/// oss servers, as the server reaches them: each host its own, answering
/// what OSSClient asks (hello, status, leases, volumes), and what each was
/// asked kept. The one at the loopback is this computer's.
final class FakeOSS: OSSTransport {
    /// This computer's oss, at its loopback.
    static let here = "http://127.0.0.1:7480"

    struct Server {
        var host: String
        var lendsContainers: Bool
        /// How many containers it has room for.
        var containerLimit = 4
        var leases: [Lease] = []
        var asked: [LeaseRequest] = []
        var released: [String] = []
        var deletedVolumes: [String] = []
    }

    private let servers: Mutex<[String: Server]>
    private let made = Mutex(0)

    /// `servers`: by the address's host, the host the server says it is on
    /// and whether it lends containers.
    init(_ servers: [String: (host: String, containers: Bool)] = ["127.0.0.1": ("this-mac", true)]) {
        self.servers = Mutex(servers.mapValues { Server(host: $0.host, lendsContainers: $0.containers) })
    }

    /// What the server at `address` (its host) was asked, and holds.
    func server(_ address: String = "127.0.0.1") -> Server { servers.withLock { $0[address]! } }

    /// Room for `limit` containers at the server at `address`.
    func roomFor(_ limit: Int, at address: String = "127.0.0.1") { servers.withLock { $0[address]?.containerLimit = limit } }

    /// A lease the server at `address` holds already.
    func hold(_ lease: Lease, at address: String = "127.0.0.1") { servers.withLock { $0[address]?.leases.append(lease) } }

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        guard let address = request.url.host, servers.withLock({ $0[address] != nil }) else { throw OSSError(status: 0, message: "could not connect") }
        let parts = request.url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "v1" else { return missing("no such request: \(request.url.path)") }
        let item = parts.count > 2 ? parts[2] : nil
        switch (request.method, parts[1], item) {
        case ("GET", "hello", nil):
            return try answer(["server": "oss", "host": server(address).host])
        case ("GET", "status", nil):
            let server = server(address)
            var bases = [Base(platform: .ios, config: "iphone")]
            var capacity = [Capacity(platform: .ios, limit: 4, leased: server.leases.filter { $0.platform == .ios }.count)]
            if server.lendsContainers {
                bases.append(Base(platform: .container, config: "default"))
                capacity.append(Capacity(platform: .container, limit: server.containerLimit,
                                         leased: server.leases.filter { $0.platform == .container }.count))
            }
            return try answer(Status(server: address, bases: bases, capacity: capacity, leases: server.leases))
        case ("GET", "machines", nil):
            return try answer(server(address).leases)
        case ("GET", "machines", let id?):
            guard let lease = server(address).leases.first(where: { $0.id == id }) else { return missing("no lease \(id)") }
            return try answer(lease)
        case ("POST", "machines", nil):
            let asked = try JSONDecoder.oss.decode(LeaseRequest.self, from: request.body ?? Data())
            let number = made.withLock { count in
                count += 1
                return count
            }
            let id = (asked.platform == .container ? "c" : "m") + String(number)
            var lease = Lease(id: id, platform: asked.platform, config: asked.config ?? "default", name: "oss-lease-" + id,
                              holder: asked.holder ?? "", state: .ready, created: Date(), expires: Date().addingTimeInterval(3600))
            lease.container = asked.container
            if asked.platform == .container { lease.execSocket = "/tmp/fake-oss-\(id).sock" }
            servers.withLock {
                $0[address]?.asked.append(asked)
                $0[address]?.leases.append(lease)
            }
            return try answer(lease)
        case ("DELETE", "machines", let id?):
            servers.withLock {
                $0[address]?.leases.removeAll { $0.id == id }
                $0[address]?.released.append(id)
            }
            return try answer(["released": id])
        case ("DELETE", "volumes", let name?):
            servers.withLock { $0[address]?.deletedVolumes.append(name) }
            return try answer(["deleted": name])
        default:
            return missing("no such request: \(request.method) \(request.url.path)")
        }
    }

    private func answer(_ value: some Encodable) throws -> OSSHTTPResponse {
        OSSHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try JSONEncoder.oss.encode(value))
    }

    private func missing(_ message: String) -> OSSHTTPResponse {
        OSSHTTPResponse(status: 404, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"\#(message)"}"#.utf8))
    }
}
