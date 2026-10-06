// The network of computers: each server has an id and tells its clients
// and peers of itself and the rest; what one learns, all learn, and
// nothing is passed on twice; a client reads a peer's API through any
// server that reaches it, with the peer's own password put in on the
// way, and never round in a circle.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class PeersTests: ServerTestCase {
    private var here: VisorServer!
    private var there: VisorServer!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-peers-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-peers-\(getpid()).sock"
        here = VisorServer(port: 7984)
        here.settings.sshEnabled = false
        here.settings.publicAddress = "http://127.0.0.1:7984"
        here.password = "here-password"
        // The other server keeps its own settings and secrets.
        let otherRoot = root.appendingPathComponent("there")
        try? FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        VisorServer.storeRoot = otherRoot
        VisorServer.secrets = MemorySecrets()
        there = VisorServer(port: 7985)
        there.settings.sshEnabled = false
        there.settings.publicAddress = "http://127.0.0.1:7985"
        there.password = "there-password"
        for _ in 0..<50 where !(here.listening && there.listening) { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    override func tearDown() async throws {
        here.stop()
        there.stop()
        VisorServer.socketPathOverride = nil
    }

    private func request(_ method: String, _ path: String, bearer: String?, body: String = "", relay: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        if let relay { headers["x-visor-relay"] = relay }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func route(_ server: VisorServer, _ request: HTTPRequest) async -> HTTPResponse {
        await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    /// A server has an id, made once and kept; hello says it, with the
    /// server's own addresses; the connection code carries it.
    func testAServerKnowsWhoItIs() throws {
        XCTAssertFalse(here.id.isEmpty)
        XCTAssertNotEqual(here.id, there.id)
        XCTAssertEqual(ServerSettings.kept(at: VisorServer.settingsURL).serverID, there.id, "kept with the settings")
        let hello = Envelope.decode(here.route(request("GET", "/api/hello", bearer: "here-password")).body)
        XCTAssertEqual(hello?.id, here.id)
        XCTAssertEqual(hello?.addresses, ["http://127.0.0.1:7984"])
        XCTAssertEqual(there.ownAddresses, ["http://127.0.0.1:7985"])
        XCTAssertEqual(there.connectionCode?.id, there.id)
        XCTAssertEqual(ConnectionCode(parsing: there.connectionCode!.encoded)?.id, there.id)
    }

    /// What is said of a computer is taken in once, more of it merged,
    /// this computer itself never; the peers are kept; and a peer from
    /// before ids reads back from the links.
    func testPeersAreTakenInMergedAndKept() {
        let other = Peer(id: "other-id", name: "Other", addresses: ["http://10.0.0.2:7433"], password: "pw")
        XCTAssertTrue(here.adopt(other))
        XCTAssertFalse(here.adopt(other), "nothing new")
        XCTAssertTrue(here.adopt(Peer(id: "other-id", name: "Other", addresses: ["logan@10.0.0.2"], password: "pw")))
        XCTAssertEqual(here.peers.map(\.addresses), [["http://10.0.0.2:7433", "logan@10.0.0.2"]])
        XCTAssertFalse(here.adopt(Peer(id: here.id, name: "Me", addresses: ["http://10.0.0.9:7433"], password: "x")), "never itself")
        // By an address in common when an id is missing.
        XCTAssertTrue(here.adopt(Peer(id: "", name: "Other again", addresses: ["http://10.0.0.2:7433", "http://10.0.0.3:7433"], password: "")))
        XCTAssertEqual(here.peers.count, 1)
        XCTAssertEqual(here.peers.first?.name, "Other again")
        XCTAssertEqual(here.peers.first?.password, "pw", "an empty password is not news")
        XCTAssertEqual(VisorServer.keptPeers(), here.peers, "kept")
        XCTAssertTrue(here.peers.first?.addresses.contains("http://10.0.0.3:7433") == true)
        XCTAssertNotNil(Peer(json: other.json))
        XCTAssertEqual(Peer(json: other.json), other)
    }

    /// The network as a client reads it, and what a client tells a
    /// server: taken in and passed on to the peers, which take it in too
    /// and pass it no further to the one who told them.
    func testWhatAClientTellsOneComputerTheRestLearn() async throws {
        let refused = await route(here, request("GET", "/api/peers", bearer: nil))
        XCTAssertEqual(refused.status, 401)
        var told = Envelope(type: "peers")
        told.peers = [there.ownPeer, Peer(id: "far-id", name: "Far", addresses: ["http://10.0.0.7:7433"], password: "far-pw")]
        let taken = await route(here, request("POST", "/api/peers", bearer: "here-password", body: told.encoded()))
        XCTAssertEqual(taken.status, 200)
        XCTAssertEqual(here.peers.map(\.id), [there.id, "far-id"])
        // Told on to the other server, which now knows this one and the far one.
        for _ in 0..<50 where there.peers.count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(Set(there.peers.map(\.id)), [here.id, "far-id"])
        XCTAssertEqual(there.peers.first { $0.id == "far-id" }?.password, "far-pw")
        let answer = await route(there, request("GET", "/api/peers", bearer: "there-password"))
        let read = Envelope.decode(answer.body)
        XCTAssertEqual(read?.id, there.id)
        XCTAssertEqual(read?.addresses, ["http://127.0.0.1:7985"])
        XCTAssertEqual(read?.peers?.count, 2)
    }

    /// A peer's API read here is carried there with the peer's password
    /// and the answer brought back; a channel there is not carried; a
    /// request that was here already goes no further.
    func testAPeerIsReadThroughThisServer() async throws {
        here.adopt(there.ownPeer)
        XCTAssertEqual(VisorServer.relayTarget("/peer/abc/api/sessions?since=3")?.id, "abc")
        XCTAssertEqual(VisorServer.relayTarget("/peer/abc/api/sessions?since=3")?.rest, "/api/sessions?since=3")
        XCTAssertEqual(VisorServer.relayTarget("/visor/peer/abc")?.rest, "/")
        XCTAssertNil(VisorServer.relayTarget("/api/sessions"))
        XCTAssertEqual(HTTPServer.requestPath(Data("GET /peer/abc/ HTTP/1.1\r\nHost: x\r\n\r\n".utf8)), "/peer/abc/")

        let unauthorized = await route(here, request("GET", "/peer/\(there.id)/api/sessions", bearer: nil))
        XCTAssertEqual(unauthorized.status, 401)
        let carried = await route(here, request("GET", "/peer/\(there.id)/api/hello", bearer: "here-password"))
        XCTAssertEqual(carried.status, 200, carried.body)
        XCTAssertEqual(Envelope.decode(carried.body)?.id, there.id, "the other server's own answer")
        XCTAssertEqual(here.workingRoads[there.id], "http://127.0.0.1:7985")
        let unknown = await route(here, request("GET", "/peer/nobody/api/hello", bearer: "here-password"))
        XCTAssertEqual(unknown.status, 404)
        let circle = await route(here, request("GET", "/peer/\(there.id)/api/hello", bearer: "here-password", relay: "x,\(here.id)"))
        XCTAssertEqual(circle.status, 508)
        // Through the other, a far one it reaches: the road is a relay too.
        there.adopt(Peer(id: "far-id", name: "Far", addresses: ["http://127.0.0.1:7984"], password: "here-password"))
        here.adopt(Peer(id: "far-id", name: "Far", addresses: ["http://10.255.255.1:7433"], password: "here-password"))
        XCTAssertEqual(here.roads(to: here.peers.first { $0.id == "far-id" }!), ["http://10.255.255.1:7433", "http://127.0.0.1:7985/peer/far-id"])
    }
}
