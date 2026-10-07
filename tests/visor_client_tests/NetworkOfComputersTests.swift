// The network of computers, as the client sees it: a server is reached
// by whichever of its paths answers, the next tried at once when one
// does not; a server says who it is and where it is reached, which the
// record keeps; a server's peers are added here with every path to them,
// one reached through another when its own addresses do not answer; and
// the servers held here are introduced to one another.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class NetworkOfComputersTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func scripted(_ record: AgentServerRecord) -> ScriptedServer {
        let server = ScriptedServer()
        ScriptedProvider.servers[record.id] = server
        return server
    }

    /// The record's address first; when it does not answer, the next
    /// path at once, with no wait between; the one that answered is
    /// tried first the next time.
    func testThePathsAreTriedInTurn() async {
        let record = AgentServerRecord(name: "Mini", address: "http://10.0.0.2:7433", secret: "pw", provider: "scripted",
                                       paths: ["logan@10.0.0.2", "http://100.90.45.11:7433"])
        let server = scripted(record)
        server.refused = ["http://10.0.0.2:7433", "logan@10.0.0.2"]
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(server.signedInBy, ["http://10.0.0.2:7433", "logan@10.0.0.2", "http://100.90.45.11:7433"])
        XCTAssertFalse(server.pauses.contains(2_000), "no retry wait between paths (the minute's poll aside)")
        XCTAssertEqual(host.path, "http://100.90.45.11:7433")
        XCTAssertEqual(host.record.address, "http://10.0.0.2:7433", "the record's address stands")

        host.disconnect()
        host.connect()
        await settle()
        XCTAssertEqual(server.signedInBy.last, "http://100.90.45.11:7433", "the path that answered, first")
        XCTAssertEqual(server.signedInBy.count, 4)
    }

    /// Every path refused: the wait, then the paths again from the start.
    func testEveryRoadRefusedMeansTheWait() async {
        let record = AgentServerRecord(name: "Mini", address: "http://a", secret: "pw", provider: "scripted", paths: ["http://b"])
        let server = scripted(record)
        server.refused = ["http://a", "http://b"]
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(server.signedInBy, ["http://a", "http://b"])
        XCTAssertTrue(server.pauses.contains(2_000), "the first retry's wait, after the round")
        server.refused = ["http://a"]
        server.elapse(2_000)
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(server.signedInBy.suffix(2), ["http://a", "http://b"])
    }

    /// What the server says of itself is kept: its id, and its own
    /// addresses as more paths.
    func testTheServerSaysWhoItIs() async {
        let record = AgentServerRecord(name: "", address: "http://127.0.0.1:7433", secret: "pw", provider: "scripted")
        let server = scripted(record)
        server.identity = ServerIdentity(id: "mini-id", addresses: ["http://100.90.45.11:7433", "logan@100.90.45.11"])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.record.serverID, "mini-id")
        XCTAssertEqual(host.record.paths, ["http://100.90.45.11:7433", "logan@100.90.45.11"])
        XCTAssertEqual(host.asPeer?.addresses, ["http://100.90.45.11:7433", "logan@100.90.45.11"], "never the loopback path")
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.paths, host.record.paths)
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.serverID, "mini-id")
    }

    /// Two servers held: each is introduced to the other; a computer one
    /// of them knows is added with its own addresses and, those not
    /// answering, reached through the server that knows it.
    func testServersAreIntroducedAndTheirPeersAdded() async throws {
        VisorHost.settings = MemorySettings()
        let a = AgentServerRecord(name: "A", address: "http://a:7433", secret: "a-pw", provider: "scripted")
        let b = AgentServerRecord(name: "B", address: "http://b:7433", secret: "b-pw", provider: "scripted")
        let serverA = scripted(a), serverB = scripted(b)
        serverA.identity = ServerIdentity(id: "A", addresses: ["http://a:7433"])
        serverB.identity = ServerIdentity(id: "B", addresses: ["http://b:7433"])
        serverA.peersAnswer = [Peer(id: "C", name: "C", addresses: ["http://c:7433"], password: "c-pw")]
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json]).encoded())
        let store = VisorStore()
        for _ in 0..<10 { await settle() }
        // C was added, with its own path and a path through A.
        let c = try XCTUnwrap(store.servers.first { $0.record.serverID == "C" })
        XCTAssertEqual(c.record.address, "http://c:7433")
        XCTAssertEqual(c.record.secret, "c-pw")
        XCTAssertEqual(store.relayPaths(to: c), ["http://a:7433/peer/C", "http://b:7433/peer/C"])
        // Each told of the others (more than once is no harm: a server
        // takes in only what is news).
        XCTAssertEqual(Set(serverA.introduced.flatMap { $0 }.map(\.id)), ["B", "C"])
        XCTAssertEqual(Set(serverB.introduced.flatMap { $0 }.map(\.id)), ["A", "C"])
        XCTAssertEqual(serverB.introduced.flatMap { $0 }.first { $0.id == "A" }?.password, "a-pw")
        // Told again of C by B: more of the same, not another record.
        store.take(Peer(id: "C", name: "C", addresses: ["http://c:7433", "logan@c"], password: ""), from: store.servers[1])
        XCTAssertEqual(store.servers.filter { $0.record.serverID == "C" }.count, 1)
        XCTAssertEqual(c.record.paths, ["logan@c"])
        XCTAssertEqual(c.record.secret, "c-pw", "an empty password is not news")
        // A's own peer entry is never added as another computer.
        store.take(Peer(id: "A", name: "A", addresses: ["http://a:7433"], password: "a-pw"), from: store.servers[1])
        XCTAssertEqual(store.servers.count, 3)
    }

    /// A computer reached by a relay path, its own not answering.
    func testAComputerIsReachedThroughAnotherWhenItsOwnPathsDoNot() async {
        let record = AgentServerRecord(name: "C", address: "http://c:7433", secret: "pw", provider: "scripted", serverID: "C")
        let server = scripted(record)
        server.refused = ["http://c:7433"]
        let host = AgentServerConnection(record: record)
        host.relayPaths = { ["http://a:7433/peer/C"] }
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://a:7433/peer/C")
    }
}
