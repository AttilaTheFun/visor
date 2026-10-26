// Servers that stand alone: reached only at the address they were added
// at, their own paths not learned, kept out of the relay (neither told of
// the others nor told of to them) — whether the server says so or its
// authenticator does. And a
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
        XCTAssertFalse(host.relayEnabled, "out of the relay")
        XCTAssertTrue(server.authorizedKeys.isEmpty, "no SSH key enrolled")
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.standalone, true)
    }

    /// One of a computer's paths reaches another computer (a bridge to a
    /// Mac's own containers, 192.168.64.1 on every Mac): that path goes and
    /// the next is tried; the computer keeps its own id (taking the other's,
    /// it was folded into that one and gone from the list).
    func testAPathThatReachesAnotherComputerGoes() async {
        VisorHost.ssh = ScriptedSSH()
        defer { VisorHost.ssh = nil }
        var record = AgentServerRecord(name: "Mini", address: "https://mini.example.com", secret: "pw", provider: "scripted",
                                       paths: ["ssh://logan@192.168.64.1"])
        record.serverID = "mini"
        let server = scripted(record)
        server.identity = ServerIdentity(id: "mini", addresses: ["https://mini.example.com"])
        server.identityAt["ssh://logan@192.168.64.1"] = ServerIdentity(id: "macbook", addresses: [])
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<20 { await settle() }
        XCTAssertEqual(server.signedInBy.first, "ssh://logan@192.168.64.1", "the shared path tried first")
        XCTAssertEqual(host.record.serverID, "mini", "its own id kept")
        XCTAssertFalse(host.record.paths.contains("ssh://logan@192.168.64.1"), "the path to the other computer is gone")
        XCTAssertEqual(host.path, "https://mini.example.com")
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
        XCTAssertFalse(host.relayEnabled)
    }

    /// In the store: a server that stands alone is told nothing of the
    /// others, and the others are told nothing of it.
    func testAServerThatStandsAloneIsKeptOutOfTheRelay() async throws {
        let a = AgentServerRecord(name: "Sandbox", address: "https://front.example.com/visor", secret: "a-pw", provider: "scripted")
        let b = AgentServerRecord(name: "Mini", address: "http://b:7433", secret: "b-pw", provider: "scripted")
        let serverA = scripted(a), serverB = scripted(b)
        serverA.identity = ServerIdentity(id: "A", addresses: [], standalone: true)
        serverB.identity = ServerIdentity(id: "B", addresses: ["http://b:7433"])
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json]).encoded())
        let store = VisorStore()
        for _ in 0..<10 { await settle() }
        await store.courier.exchangeAll()
        XCTAssertTrue(serverA.reports.isEmpty, "it is told nothing")
        XCTAssertFalse(serverB.reports.isEmpty)
        XCTAssertFalse(serverB.reports.flatMap(\.servers).contains { $0.id == "A" }, "it is told of to no one")
    }

    /// Added again from a code: a code that does not say how to sign in
    /// leaves the held computer's sign-in; one that says changes it; a
    /// server that stands alone keeps its address and sign-in either way.
    func testACodeChangesTheSignInOnlyWhenItSaysHow() {
        let store = VisorStore()
        let first = store.open(ConnectionCode(name: "Mini", host: "http://100.64.0.11:7433", password: "pw", id: "mini", auth: "none").link)
        XCTAssertEqual(first?.record.authentication, NoAuthenticator.name, "the code said none")
        _ = store.open(ConnectionCode(name: "Mini", host: "http://100.64.0.11:7433", password: "pw2", id: "mini").link)
        XCTAssertEqual(first?.record.authentication, NoAuthenticator.name, "a code that does not say leaves it")
        _ = store.open(ConnectionCode(name: "Mini", host: "http://100.64.0.11:7433", password: "pw3", id: "mini", auth: "password").link)
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
