// Servers that stand alone: reached only at the address they were added
// at, their own paths not learned, their peers not taken in, neither
// introduced to the others nor the others to them, their credential sent
// nowhere — whether the server says so or its authenticator does. And a
// connection code that does not say how to sign in leaves a held
// computer's sign-in as it is.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A front's sign-in that cannot change the server behind it.
@MainActor
struct FrontAuthenticator: AgentServerAuthenticator {
    static let name = "front"
    let id = FrontAuthenticator.name
    let title = "Front"
    var isolated: Bool { true }
    func headers(for record: AgentServerRecord) async throws -> [String: String] { ["X-Front": record.secret] }
}

@MainActor
final class StandaloneServerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        AgentServerAuthenticators.register(FrontAuthenticator())
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

    /// A server that says it stands alone: the paths learned under the
    /// network of computers go, none is learned, only its address is
    /// tried, and it is no one's peer.
    func testAServerThatStandsAloneIsReachedOnlyWhereItWasAdded() async {
        VisorHost.ssh = ScriptedSSH()
        defer { VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Sandbox", address: "https://front.example.com/visor", secret: "pw", provider: "scripted",
                                       paths: ["ssh://agent@10.0.0.9", "http://10.0.0.9:7433"])
        let server = scripted(record)
        server.identity = ServerIdentity(id: "sandbox", addresses: ["http://10.0.0.9:7433", "ssh://agent@10.0.0.9"], standalone: true)
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(host.state, .connected)
        // Before it had said so, a path learned under the network of
        // computers came first; the sign-in there is let go at once, and
        // the server is reached at its address alone from then on.
        XCTAssertEqual(server.signedInBy, ["ssh://agent@10.0.0.9", "https://front.example.com/visor"])
        XCTAssertEqual(host.path, "https://front.example.com/visor")
        XCTAssertEqual(server.channels, 1, "no channel opened around the front")
        XCTAssertTrue(host.record.standalone)
        XCTAssertEqual(host.record.paths, [], "the learned paths are gone, and none is learned")
        XCTAssertEqual(host.pathsToTry(), ["https://front.example.com/visor"])
        XCTAssertNil(host.asPeer, "its address and credential go to no one")
        XCTAssertTrue(server.authorizedKeys.isEmpty, "no SSH key enrolled")
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.standalone, true)
    }

    /// An authenticator that isolates: the same, whatever the server says.
    func testAnIsolatingAuthenticatorKeepsTheServerAlone() async {
        let record = AgentServerRecord(name: "Sandbox", address: "https://front.example.com/visor", secret: "token", provider: "scripted",
                                       paths: ["http://10.0.0.9:7433"], authentication: FrontAuthenticator.name)
        let server = scripted(record)
        server.identity = ServerIdentity(id: "sandbox", addresses: ["http://10.0.0.9:7433"])
        let host = AgentServerConnection(record: record)
        XCTAssertTrue(host.isolated)
        host.connect()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(server.signedInBy, ["https://front.example.com/visor"])
        XCTAssertEqual(host.pathsToTry(), ["https://front.example.com/visor"])
        XCTAssertNil(host.asPeer)
    }

    /// In the store: a server that stands alone is not asked for its
    /// peers, is not introduced to the others nor they to it, and is no
    /// relay to anything.
    func testAServerThatStandsAloneSharesNothingInTheStore() async throws {
        let a = AgentServerRecord(name: "Sandbox", address: "https://front.example.com/visor", secret: "a-pw", provider: "scripted")
        let b = AgentServerRecord(name: "Mini", address: "http://b:7433", secret: "b-pw", provider: "scripted")
        let serverA = scripted(a), serverB = scripted(b)
        serverA.identity = ServerIdentity(id: "A", addresses: [], standalone: true)
        serverB.identity = ServerIdentity(id: "B", addresses: ["http://b:7433"])
        serverA.peersAnswer = [Peer(id: "C", name: "C", addresses: ["http://c:7433"], password: "c-pw")]
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json]).encoded())
        let store = VisorStore()
        for _ in 0..<10 { await settle() }
        XCTAssertEqual(store.servers.count, 2, "its peers are not taken in")
        XCTAssertTrue(serverA.introduced.isEmpty, "the others are not introduced to it")
        XCTAssertFalse(serverB.introduced.flatMap { $0 }.contains { $0.id == "A" }, "it is introduced to no one")
        let sandbox = try XCTUnwrap(store.servers.first { $0.record.serverID == "A" })
        let mini = try XCTUnwrap(store.servers.first { $0.record.serverID == "B" })
        XCTAssertEqual(store.relayPaths(to: sandbox), [])
        XCTAssertFalse(store.relayPaths(to: mini).contains { $0.hasPrefix("https://front.example.com") }, "it relays nothing")
        // Told of it by another: nothing learned.
        store.take(Peer(id: "A", name: "Sandbox", addresses: ["http://10.0.0.9:7433"], password: "x"), from: mini)
        XCTAssertEqual(sandbox.record.paths, [])
    }

    /// Added again from a code: a code that does not say how to sign in
    /// leaves the held computer's sign-in; one that says changes it; a
    /// server that stands alone keeps its address and sign-in either way.
    func testACodeChangesTheSignInOnlyWhenItSaysHow() {
        let store = VisorStore()
        let first = store.open(ConnectionCode(name: "Mini", host: "http://100.90.45.11:7433", password: "pw", id: "mini", auth: "none").link)
        XCTAssertEqual(first?.record.authentication, NoAuthenticator.name, "the code said none")
        _ = store.open(ConnectionCode(name: "Mini", host: "http://100.90.45.11:7433", password: "pw2", id: "mini").link)
        XCTAssertEqual(first?.record.authentication, NoAuthenticator.name, "a code that does not say leaves it")
        _ = store.open(ConnectionCode(name: "Mini", host: "http://100.90.45.11:7433", password: "pw3", id: "mini", auth: "password").link)
        XCTAssertEqual(first?.record.authentication, PasswordAuthenticator.name)
        XCTAssertEqual(ConnectionCode(parsing: ConnectionCode(name: "x", host: "http://a", password: "p", auth: "none").link)?.auth, "none")

        let sandbox = store.add(AgentServerRecord(name: "Sandbox", address: "https://front.example.com/visor", secret: "token",
                                                  serverID: "sandbox", authentication: FrontAuthenticator.name))
        XCTAssertTrue(sandbox.isolated)
        _ = store.open(ConnectionCode(name: "Sandbox", host: "http://10.0.0.9:7433", password: "pw", id: "sandbox", auth: "password").link)
        XCTAssertEqual(sandbox.record.address, "https://front.example.com/visor", "its address stands")
        XCTAssertEqual(sandbox.record.authentication, FrontAuthenticator.name, "its sign-in stands")
        XCTAssertEqual(sandbox.record.secret, "token")
    }
}
