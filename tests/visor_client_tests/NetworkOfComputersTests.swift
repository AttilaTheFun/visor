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

/// The device's networks as the test says them: which hosts are on a
/// network of its own, and whether it has a tailnet address.
@MainActor
final class ScriptedNetwork: VisorNetworkService {
    var local: Set<String> = []
    var hasVPN = true
    var onChange: (@MainActor () -> Void)?
    func isOnLocalNetwork(_ host: String) -> Bool { local.contains(host) }
}

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
        server.identity = ServerIdentity(id: "mini-id", addresses: ["http://100.90.45.11:7433", "logan@100.90.45.11"], sshKey: "ssh-ed25519 AAAAmini visor-server")
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.record.serverID, "mini-id")
        XCTAssertEqual(host.record.serverKey, "ssh-ed25519 AAAAmini visor-server")
        XCTAssertEqual(host.asPeer?.sshKey, "ssh-ed25519 AAAAmini visor-server", "introduced with its key")
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.serverKey, host.record.serverKey)
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

    /// A record whose address is the computer's SSH, before the computer
    /// knows this device's key: SSH refuses, another path lets the device
    /// in, its key is handed over, and SSH is tried again and taken.
    func testAComputerAskedForOverSSHEnrollsByAnotherPath() async {
        let ssh = ScriptedSSH()
        VisorHost.ssh = ssh
        defer { VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Mini", address: "ssh://logan@10.0.0.2", secret: "pw", provider: "scripted", paths: ["http://10.0.0.2:7433"])
        let server = scripted(record)
        server.refused = ["ssh://logan@10.0.0.2"]
        server.onAuthorize = { server.refused = [] }
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(server.authorizedKeys, ["ssh-ed25519 AAAAdevice visor"])
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "ssh://logan@10.0.0.2", "over SSH, once the key is known")
        XCTAssertEqual(server.signedInBy, ["ssh://logan@10.0.0.2", "http://10.0.0.2:7433", "ssh://logan@10.0.0.2"])
    }

    /// Use SSH: the record's address becomes the SSH path on the same
    /// host, the old one another path, and the key is handed over by it.
    func testUseSSHSwitchesTheAddressAndEnrolls() async {
        let ssh = ScriptedSSH()
        VisorHost.ssh = ssh
        defer { VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Mini", address: "http://10.0.0.2:7433", secret: "pw", provider: "scripted",
                                       paths: ["ssh://logan@100.90.45.11", "ssh://logan@10.0.0.2"])
        let server = scripted(record)
        server.refused = ["ssh://logan@10.0.0.2", "ssh://logan@100.90.45.11"]
        server.onAuthorize = { server.refused = [] }
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.path, "http://10.0.0.2:7433")
        XCTAssertTrue(host.authorizedNothingYet(server))
        XCTAssertTrue(host.useSSH())
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(host.record.address, "ssh://logan@10.0.0.2", "the SSH path on the same host")
        XCTAssertTrue(host.record.paths.contains("http://10.0.0.2:7433"))
        XCTAssertEqual(server.authorizedKeys.count, 1)
        XCTAssertEqual(host.path, "ssh://logan@10.0.0.2")
        XCTAssertFalse(AgentServerConnection(record: AgentServerRecord(name: "", address: "http://x", provider: "scripted")).useSSH(), "no SSH path known")
    }

    /// The connection code carries the paths; the SSH code puts one first.
    func testTheCodeCarriesThePaths() {
        let code = ConnectionCode(name: "Mini", host: "http://100.90.45.11:7433", password: "pw", id: "mini",
                                  paths: ["http://192.168.4.52:7433", "ssh://logan@100.90.45.11", "http://100.90.45.11:7433"])
        XCTAssertEqual(code.paths, ["http://192.168.4.52:7433", "ssh://logan@100.90.45.11"], "the host itself is not a path twice")
        let read = ConnectionCode(parsing: code.link)
        XCTAssertEqual(read, code)
        XCTAssertEqual(read?.peer.addresses.count, 3)
        let ssh = code.preferringSSH
        XCTAssertEqual(ssh?.host, "ssh://logan@100.90.45.11")
        XCTAssertEqual(ssh?.paths, ["http://100.90.45.11:7433", "http://192.168.4.52:7433"])
        XCTAssertNil(ConnectionCode(name: "x", host: "http://a", password: "p").preferringSSH)
        // Read into the store: the paths come along.
        VisorHost.settings = MemorySettings()
        let store = VisorStore()
        let added = store.open(ssh!.link)
        XCTAssertEqual(added?.record.address, "ssh://logan@100.90.45.11")
        XCTAssertEqual(added?.record.paths, ["http://100.90.45.11:7433", "http://192.168.4.52:7433"])
        XCTAssertEqual(added?.record.serverID, "mini")
    }
    /// A connection code for a computer held already puts its address
    /// first: the SSH code switches a computer held over HTTP to SSH.
    func testACodeForAComputerHeldSwitchesItsAddress() {
        VisorHost.settings = MemorySettings()
        let store = VisorStore()
        let first = store.open(ConnectionCode(name: "Mini", host: "http://100.90.45.11:7433", password: "pw", id: "mini").link)
        XCTAssertEqual(first?.record.address, "http://100.90.45.11:7433")
        let ssh = ConnectionCode(name: "Mini", host: "ssh://logan@100.90.45.11", password: "pw", id: "mini", paths: ["http://100.90.45.11:7433"])
        let again = store.open(ssh.link)
        XCTAssertTrue(again === first, "the same computer, not another")
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(again?.record.address, "ssh://logan@100.90.45.11")
        XCTAssertTrue(again?.record.paths.contains("http://100.90.45.11:7433") == true)
    }

    /// Where the device is ranks the paths: the LAN's address first at
    /// home, the tailnet's away (and the LAN's last, out of reach), and
    /// a change of networks moves the connection to the path that fits.
    func testThePathThatFitsTheNetworkComesFirst() async {
        let network = ScriptedNetwork()
        VisorHost.network = network
        defer { VisorHost.network = nil }
        let record = AgentServerRecord(name: "Mini", address: "ssh://logan@100.90.45.11", secret: "pw", provider: "scripted",
                                       paths: ["ssh://logan@192.168.4.52", "http://100.90.45.11:7433", "http://192.168.4.52:7433"])
        let server = scripted(record)
        // Away: the LAN's addresses are out of reach, the tailnet's first.
        network.local = []
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://logan@192.168.4.52"), .unlikely)
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://logan@100.90.45.11"), .overlay)
        XCTAssertEqual(AgentServerConnection.fit(of: "https://proxy.example.com/visor"), .other)
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.path, "ssh://logan@100.90.45.11")
        XCTAssertEqual(server.signedInBy, ["ssh://logan@100.90.45.11"], "the LAN was not even tried")
        // Home: the LAN is back, and the connection moves to it at once.
        network.local = ["192.168.4.52"]
        host.networkChanged()
        await settle()
        XCTAssertEqual(host.path, "ssh://logan@192.168.4.52")
        XCTAssertEqual(server.signedInBy.last, "ssh://logan@192.168.4.52")
        // Still home, nothing else changed: left alone.
        let count = server.signedInBy.count
        host.networkChanged()
        await settle()
        XCTAssertEqual(server.signedInBy.count, count)
        // Away again with the tailnet off: nothing fits better than the
        // path in use, so the connection is left where it is until it drops.
        network.local = []
        network.hasVPN = false
        let before = server.signedInBy.count
        host.networkChanged()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(server.signedInBy.count, before)
    }

    /// A device's key as a link, scanned by a device that holds the
    /// computers: handed to every computer connected, which authorize it.
    func testAScannedKeyIsAuthorizedOnEveryComputerConnected() async {
        let link = SSHKeyLink(key: "ssh-ed25519 AAAAipad visor")
        XCTAssertTrue(link.link.hasPrefix("visor://authorize?key="))
        XCTAssertEqual(SSHKeyLink(parsing: " " + link.link + "\n"), link)
        XCTAssertNil(SSHKeyLink(parsing: "visor://connect?code=abc"))
        XCTAssertNil(ConnectionCode(parsing: link.link), "not a connection code")
        VisorHost.settings = MemorySettings()
        let a = AgentServerRecord(name: "A", address: "http://a:7433", secret: "a-pw", provider: "scripted")
        let b = AgentServerRecord(name: "B", address: "http://b:7433", secret: "b-pw", provider: "scripted")
        let serverA = scripted(a), serverB = scripted(b)
        serverB.refused = ["http://b:7433"]
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json]).encoded())
        let store = VisorStore()
        for _ in 0..<5 { await settle() }
        XCTAssertNil(store.open(link.link))
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(serverA.authorizedKeys, ["ssh-ed25519 AAAAipad visor"])
        XCTAssertTrue(serverB.authorizedKeys.isEmpty, "not connected: not handed the key")
        XCTAssertEqual(store.notice, "The device's key is authorized on Scripted Mac: it can connect over SSH now.")
    }
}

private extension AgentServerConnection {
    func authorizedNothingYet(_ server: ScriptedServer) -> Bool { server.authorizedKeys.isEmpty }
}
