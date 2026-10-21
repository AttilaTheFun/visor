// A computer's network paths, as the client sees them: a server is reached
// by whichever of its paths answers, the next tried at once when one does
// not; and a server says who it is and where it is reached, which the
// record keeps.

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
                                       paths: ["me@10.0.0.2", "http://100.64.0.11:7433"])
        let server = scripted(record)
        server.refused = ["http://10.0.0.2:7433", "me@10.0.0.2"]
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        // (No SSH on this device: its SSH path is not tried.)
        XCTAssertEqual(server.signedInBy, ["http://10.0.0.2:7433", "http://100.64.0.11:7433"])
        XCTAssertFalse(server.pauses.contains(2_000), "no retry wait between paths (the minute's poll aside)")
        XCTAssertEqual(host.path, "http://100.64.0.11:7433")
        XCTAssertEqual(host.record.address, "http://10.0.0.2:7433", "the record's address stands")

        host.disconnect()
        host.connect()
        await settle()
        XCTAssertEqual(server.signedInBy.last, "http://100.64.0.11:7433", "the path that answered, first")
        XCTAssertEqual(server.signedInBy.count, 3)
    }

    /// The path that answered is kept in the record: the next launch (a
    /// new connection from the saved record) tries it first among those
    /// that fit as well.
    func testTheLastPathIsTriedFirstAtTheNextLaunch() async {
        let record = AgentServerRecord(name: "Mini", address: "http://10.0.0.9:7433", secret: "pw", provider: "scripted",
                                       paths: ["http://10.0.0.2:7433"])
        let server = scripted(record)
        server.refused = ["http://10.0.0.9:7433"]
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.record.lastPath, "http://10.0.0.2:7433")
        let saved = AgentServerRecord(json: host.record.json)
        XCTAssertEqual(saved?.lastPath, "http://10.0.0.2:7433")
        let launched = AgentServerConnection(record: saved!)
        launched.connect()
        await settle()
        XCTAssertEqual(server.signedInBy.suffix(1), ["http://10.0.0.2:7433"], "the stale address was not tried again first")
    }

    /// The paths are the server's own word at each sign-in: an IP it no
    /// longer gives (a lease that moved, a link-local address, a bridge
    /// to a virtual machine) goes; a name stays after them, as does the
    /// path the last sign-in answered on.
    func testPathsTheServerNoLongerGivesGo() {
        var record = AgentServerRecord(name: "Mini", address: "ssh://me@192.168.1.49", provider: "scripted",
                                       paths: ["ssh://me@169.254.179.38", "http://192.168.64.1:7433", "https://proxy.example.com/visor",
                                               "http://203.0.113.5:7433", "http://[fe80::1]:7433"],
                                       lastPath: "http://203.0.113.5:7433")
        XCTAssertTrue(record.takePaths(["http://192.168.1.49:7433", "ssh://me@192.168.1.49", "ssh://me@100.64.0.11"]))
        XCTAssertEqual(record.paths, ["http://192.168.1.49:7433", "ssh://me@100.64.0.11", "https://proxy.example.com/visor",
                                      "http://203.0.113.5:7433"])
        XCTAssertFalse(record.takePaths(["http://192.168.1.49:7433", "ssh://me@100.64.0.11"]), "nothing new")
        XCTAssertFalse(record.takePaths([]), "a server that gives none leaves them")
        XCTAssertTrue(AgentServerRecord.isIP("fe80::1"))
        XCTAssertFalse(AgentServerRecord.isIP("studio-mac.tail1234.ts.net"))
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://me@169.254.179.38"), .other, "no network service: nothing known")
    }

    /// A link's own address (169.254) is a LAN's: out of reach unless
    /// the device is on that link.
    func testALinkLocalAddressIsUnlikelyOffItsLink() {
        let network = ScriptedNetwork()
        VisorHost.network = network
        defer { VisorHost.network = nil }
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://me@169.254.179.38"), .unlikely)
        network.local = ["169.254.179.38"]
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://me@169.254.179.38"), .local)
    }

    /// The networks speaking while a sign-in is on its way by the path
    /// that fits best (the system's first word at launch): it is left to
    /// finish, not started over.
    func testANetworkChangeLeavesASignInOnTheBestPath() async {
        let network = ScriptedNetwork()
        VisorHost.network = network
        defer { VisorHost.network = nil }
        network.local = ["192.168.1.49"]
        let record = AgentServerRecord(name: "Mini", address: "http://192.168.1.49:7433", secret: "pw", provider: "scripted",
                                       paths: ["http://100.64.0.11:7433"])
        let server = scripted(record)
        server.hangs = true
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        host.networkChanged()
        await settle()
        XCTAssertEqual(server.pauses.filter { $0 == AgentServerConnection.localSignInTimeout }.count, 1, "one sign-in, not two")
        XCTAssertEqual(host.state, .connecting)
        // A LAN path that does not answer is left after 2 s, not 5.
        server.hangs = false
        server.elapse(AgentServerConnection.localSignInTimeout)
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://100.64.0.11:7433")
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
        server.identity = ServerIdentity(id: "mini-id", addresses: ["http://100.64.0.11:7433", "me@100.64.0.11"])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.record.serverID, "mini-id")
        XCTAssertEqual(host.record.paths, ["http://100.64.0.11:7433", "me@100.64.0.11"])
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.paths, host.record.paths)
        XCTAssertEqual(AgentServerRecord(json: host.record.json)?.serverID, "mini-id")
    }

    /// A record whose address is the computer's SSH, before the computer
    /// knows this device's key: SSH refuses, another path lets the device
    /// in, its key is handed over, and SSH is tried again and taken.
    func testAComputerAskedForOverSSHEnrollsByAnotherPath() async {
        let ssh = ScriptedSSH()
        VisorHost.ssh = ssh
        defer { VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Mini", address: "ssh://me@10.0.0.2", secret: "pw", provider: "scripted", paths: ["http://10.0.0.2:7433"])
        let server = scripted(record)
        server.refused = ["ssh://me@10.0.0.2"]
        server.onAuthorize = { server.refused = [] }
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(server.authorizedKeys, ["ssh-ed25519 AAAAdevice visor"])
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "ssh://me@10.0.0.2", "over SSH, once the key is known")
        XCTAssertEqual(server.signedInBy, ["ssh://me@10.0.0.2", "http://10.0.0.2:7433", "ssh://me@10.0.0.2"])
    }

    /// SSH is the way in wherever the device has it: a computer held by
    /// its HTTP address, with SSH paths, is tried over SSH first; refused
    /// (its key not known yet), it is reached over HTTP, hands its key
    /// over, and is on SSH from then on, with no Use SSH asked for.
    func testSSHIsTheWayInWhereTheDeviceHasIt() async {
        let ssh = ScriptedSSH()
        VisorHost.ssh = ssh
        defer { VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Mini", address: "http://10.0.0.2:7433", secret: "pw", provider: "scripted",
                                       paths: ["ssh://me@100.64.0.11", "ssh://me@10.0.0.2"])
        let server = scripted(record)
        server.refused = ["ssh://me@10.0.0.2", "ssh://me@100.64.0.11"]
        server.onAuthorize = { server.refused = [] }
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(server.signedInBy.prefix(3), ["ssh://me@100.64.0.11", "ssh://me@10.0.0.2", "http://10.0.0.2:7433"],
                       "SSH before HTTP")
        XCTAssertEqual(server.authorizedKeys.count, 1)
        XCTAssertEqual(host.state, .connected)
        XCTAssertTrue(host.path.map { SSHAddress($0) != nil } ?? false, "on SSH once the key is known")
        XCTAssertEqual(host.record.address, "http://10.0.0.2:7433", "the address stands; the order is the device's")
        // Use SSH still makes the SSH path on the same host the address.
        XCTAssertTrue(host.useSSH())
        XCTAssertEqual(host.record.address, "ssh://me@10.0.0.2")
        XCTAssertFalse(AgentServerConnection(record: AgentServerRecord(name: "", address: "http://x", provider: "scripted")).useSSH(), "no SSH path known")
    }

    /// At home SSH over the LAN, away SSH over the tailnet: HTTP over the
    /// LAN does not come before SSH over the tailnet.
    func testSSHComesBeforeHTTPOnEveryNetwork() {
        let ssh = ScriptedSSH()
        VisorHost.ssh = ssh
        let network = ScriptedNetwork()
        VisorHost.network = network
        defer { VisorHost.ssh = nil; VisorHost.network = nil }
        let record = AgentServerRecord(name: "Mini", address: "http://192.168.1.52:7433", secret: "pw", provider: "scripted",
                                       paths: ["http://100.64.0.11:7433", "ssh://me@100.64.0.11", "ssh://me@192.168.1.52"])
        let host = AgentServerConnection(record: record)
        network.local = ["192.168.1.52"]
        XCTAssertEqual(host.pathsToTry(), ["ssh://me@192.168.1.52", "ssh://me@100.64.0.11", "http://192.168.1.52:7433",
                                           "http://100.64.0.11:7433"])
        network.local = []
        XCTAssertEqual(host.pathsToTry().prefix(2), ["ssh://me@100.64.0.11", "http://100.64.0.11:7433"])
        // Without SSH on the device, its SSH paths are not tried at all.
        VisorHost.ssh = nil
        network.local = ["192.168.1.52"]
        XCTAssertEqual(host.pathsToTry(), ["http://192.168.1.52:7433", "http://100.64.0.11:7433"])
    }

    /// The connection code carries the paths; the SSH code puts one first,
    /// and so for HTTP and HTTPS.
    func testTheCodeCarriesThePaths() {
        let code = ConnectionCode(name: "Mini", host: "http://100.64.0.11:7433", password: "pw", id: "mini",
                                  paths: ["http://192.168.1.52:7433", "ssh://me@100.64.0.11", "http://100.64.0.11:7433"])
        XCTAssertEqual(code.paths, ["http://192.168.1.52:7433", "ssh://me@100.64.0.11"], "the host itself is not a path twice")
        let read = ConnectionCode(parsing: code.link)
        XCTAssertEqual(read, code)
        XCTAssertEqual(read.map { [$0.host] + $0.paths }?.count, 3)
        // The codes the menu bar app and the computer's settings show: the
        // QR code's, and one leading with each kind of path it has.
        let codes = ConnectionCodes(code)
        XCTAssertEqual(codes.qr, code.encoded)
        XCTAssertEqual(codes.link, code.link)
        XCTAssertEqual(codes.http, code.encoded, "it leads with HTTP already")
        XCTAssertNil(codes.https)
        XCTAssertEqual(codes.ssh, code.preferringSSH?.encoded)
        XCTAssertEqual(ConnectionCode(parsing: ConnectionCodes(ConnectionCode(name: "x", host: "mini.example.ts.net", password: "p",
                                                                              paths: ["me@10.0.0.2"])).ssh ?? "")?.host, "me@10.0.0.2")
        let ssh = code.preferringSSH
        XCTAssertEqual(ssh?.host, "ssh://me@100.64.0.11")
        XCTAssertEqual(ssh?.paths, ["http://100.64.0.11:7433", "http://192.168.1.52:7433"])
        XCTAssertNil(ConnectionCode(name: "x", host: "http://a", password: "p").preferringSSH)
        // Read into the store: the paths come along.
        VisorHost.settings = MemorySettings()
        let store = VisorStore()
        let added = store.open(ssh!.link)
        XCTAssertEqual(added?.record.address, "ssh://me@100.64.0.11")
        XCTAssertEqual(added?.record.paths, ["http://100.64.0.11:7433", "http://192.168.1.52:7433"])
        XCTAssertEqual(added?.record.serverID, "mini")
    }
    /// A connection code for a computer held already puts its address
    /// first: the SSH code switches a computer held over HTTP to SSH.
    func testACodeForAComputerHeldSwitchesItsAddress() {
        VisorHost.settings = MemorySettings()
        let store = VisorStore()
        let first = store.open(ConnectionCode(name: "Mini", host: "http://100.64.0.11:7433", password: "pw", id: "mini").link)
        XCTAssertEqual(first?.record.address, "http://100.64.0.11:7433")
        let ssh = ConnectionCode(name: "Mini", host: "ssh://me@100.64.0.11", password: "pw", id: "mini", paths: ["http://100.64.0.11:7433"])
        let again = store.open(ssh.link)
        XCTAssertTrue(again === first, "the same computer, not another")
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(again?.record.address, "ssh://me@100.64.0.11")
        XCTAssertTrue(again?.record.paths.contains("http://100.64.0.11:7433") == true)
    }

    /// Where the device is ranks the paths: the LAN's address first at
    /// home, the tailnet's away (and the LAN's last, out of reach), and
    /// a change of networks moves the connection to the path that fits.
    func testThePathThatFitsTheNetworkComesFirst() async {
        let network = ScriptedNetwork()
        VisorHost.network = network
        VisorHost.ssh = ScriptedSSH()
        defer { VisorHost.network = nil; VisorHost.ssh = nil }
        let record = AgentServerRecord(name: "Mini", address: "ssh://me@100.64.0.11", secret: "pw", provider: "scripted",
                                       paths: ["ssh://me@192.168.1.52", "http://100.64.0.11:7433", "http://192.168.1.52:7433"])
        let server = scripted(record)
        // Away: the LAN's addresses are out of reach, the tailnet's first.
        network.local = []
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://me@192.168.1.52"), .unlikely)
        XCTAssertEqual(AgentServerConnection.fit(of: "ssh://me@100.64.0.11"), .overlay)
        XCTAssertEqual(AgentServerConnection.fit(of: "https://proxy.example.com/visor"), .other)
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.path, "ssh://me@100.64.0.11")
        XCTAssertEqual(server.signedInBy, ["ssh://me@100.64.0.11"], "the LAN was not even tried")
        // Home: the LAN is back, and the connection moves to it at once.
        network.local = ["192.168.1.52"]
        host.networkChanged()
        await settle()
        XCTAssertEqual(host.path, "ssh://me@192.168.1.52")
        XCTAssertEqual(server.signedInBy.last, "ssh://me@192.168.1.52")
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

    /// The networks speaking several times at once (the monitor starting,
    /// an interface coming up) restart the sign-ins once, after they
    /// settle, not once a word.
    func testNetworkChangesAreActedOnOnceTheySettle() async throws {
        let network = ScriptedNetwork()
        VisorHost.network = network
        defer { VisorHost.network = nil }
        VisorHost.settings = MemorySettings()
        let record = AgentServerRecord(name: "Mini", address: "http://192.168.1.52:7433", secret: "pw", provider: "scripted",
                                       paths: ["http://100.64.0.11:7433"])
        let server = scripted(record)
        network.local = []
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([record.json]).encoded())
        let store = VisorStore()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.first?.state, .connected)
        let before = server.signedInBy.count
        network.local = ["192.168.1.52"]
        for _ in 0..<5 { network.onChange?() }
        try await Task.sleep(nanoseconds: VisorStore.networkSettling + 200_000_000)
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(server.signedInBy.count, before + 1, "one restart for five words")
        XCTAssertEqual(server.signedInBy.last, "http://192.168.1.52:7433")
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

    /// A sign-in link names a computer by its address, whatever the
    /// address holds; opened, that computer's settings are asked for.
    func testASignInLinkShowsItsComputersSettings() async {
        let link = SignInLink(computer: "https://host/path?x=1")
        XCTAssertEqual(link.link, "visor://sign-in?computer=https%3A%2F%2Fhost%2Fpath%3Fx%3D1")
        XCTAssertEqual(SignInLink(parsing: " " + link.link + "\n"), link)
        XCTAssertNil(SignInLink(parsing: "visor://sign-in?other=1"))
        XCTAssertNil(SignInLink(parsing: "visor://connect?code=abc"))
        VisorHost.settings = MemorySettings()
        let a = AgentServerRecord(name: "A", address: "https://host/path?x=1", secret: "a-pw", provider: "scripted")
        _ = scripted(a)
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json]).encoded())
        let store = VisorStore()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.open(link.link)?.record.address, a.address)
        XCTAssertEqual(store.openingSettings, a.address)
        store.openingSettings = nil
        XCTAssertNil(store.open(SignInLink(computer: "https://elsewhere").link), "a computer not held here")
        XCTAssertNil(store.openingSettings)
    }
}

private extension AgentServerConnection {
    func authorizedNothingYet(_ server: ScriptedServer) -> Bool { server.authorizedKeys.isEmpty }
}
