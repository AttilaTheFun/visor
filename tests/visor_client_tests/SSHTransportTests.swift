// A server reached over SSH, through the one address provider: the
// record's `user@host[:port]` (through jump hosts with `?via=`) opened
// through the host's SSH with the device's key, each computer's host key
// kept the first time and compared after, a port forwarded to the
// server's loopback, and the HTTP sign-in through it. What SSH refuses is
// said as the connection says it: a changed host key as a message, a
// refused key as a sign-in to redo.

import Foundation
import Synchronization
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// SSH as the test scripts it: every connect is recorded, and answers a
/// session or fails as told.
@MainActor
final class ScriptedSSH: VisorSSHService {
    var connects: [(route: [VisorSSHHop], hostKeys: [String?])] = []
    var failure: VisorSSHError?
    var hostKeysGiven = ["ssh-ed25519 AAAAhost mini"]
    var sessions: [ScriptedSSHSession] = []

    func publicKey() -> String { "ssh-ed25519 AAAAdevice visor" }

    func connect(_ route: [VisorSSHHop], hostKeys: [String?]) async throws -> any VisorSSHSession {
        connects.append((route, hostKeys))
        if let failure { throw failure }
        let session = ScriptedSSHSession(hostKeys: hostKeysGiven)
        sessions.append(session)
        return session
    }
}

@MainActor
final class ScriptedSSHSession: VisorSSHSession {
    let hostKeys: [String]
    var forwarded: [Int] = []
    var attached: [String] = []
    var closed = false
    init(hostKeys: [String]) { self.hostKeys = hostKeys }
    func forward(toPort port: Int) async throws -> Int { forwarded.append(port); return 54321 }
    func attach(command: String) async throws -> Int { attached.append(command); return 60001 }
    func close() { closed = true }
}

/// HTTP that records where it was asked, and answers hello — except at
/// a port that answers nothing (a server with no socket file: the
/// command there ends at once, and so does the connection).
final class RecordingHTTP: VisorHTTPService {
    private let asked = Mutex<[String]>([])
    private let dead = Mutex<Set<Int>>([])
    var urls: [String] { asked.withLock { $0 } }
    var bearers: [String] { tokens.withLock { $0 } }
    private let tokens = Mutex<[String]>([])
    func kill(port: Int) { dead.withLock { _ = $0.insert(port) } }
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        asked.withLock { $0.append(url) }
        tokens.withLock { $0.append(authorization) }
        if dead.withLock({ $0.contains { url.hasPrefix("http://127.0.0.1:\($0)/") } }) { throw ScriptedFailure(status: 0) }
        if url.hasSuffix("/api/hello") { return Envelope.hello(host: "Mini", login: "", token: "tok-1").encoded() }
        return Envelope(type: "reply").encoded()
    }
    func status(of error: Error) -> Int? { (error as? ScriptedFailure)?.status }
}

@MainActor
final class SSHTransportTests: XCTestCase {
    private var ssh: ScriptedSSH!
    private var http: RecordingHTTP!
    private var settings: MemorySettings!

    override func setUp() async throws {
        try await super.setUp()
        ssh = ScriptedSSH()
        http = RecordingHTTP()
        settings = MemorySettings()
        VisorHost.ssh = ssh
        VisorHost.http = http
        VisorHost.settings = settings
    }

    override func tearDown() async throws {
        VisorHost.ssh = nil
    }

    private func record(_ address: String = "logan@mini.local") -> AgentServerRecord {
        AgentServerRecord(name: "Mini", address: address, secret: "pw")
    }

    /// The address is a user and a host, with a port when one is given
    /// and the jump hosts after `?via=`; an `ssh://` prefix and the
    /// spaces around are not minded; anything else is not one.
    func testTheAddressIsUserAtHostWithAPortAndTheWayThere() {
        let plain = SSHAddress("logan@mini.local")
        XCTAssertEqual(plain?.target, SSHAddress.Hop(user: "logan", host: "mini.local", port: 22))
        XCTAssertEqual(plain?.via, [])
        let full = SSHAddress(" ssh://logan@100.90.45.11:2299?via=me@jump.example,me@inner:2200\n")
        XCTAssertEqual(full?.target, SSHAddress.Hop(user: "logan", host: "100.90.45.11", port: 2299))
        XCTAssertEqual(full?.via, [SSHAddress.Hop(user: "me", host: "jump.example"), SSHAddress.Hop(user: "me", host: "inner", port: 2200)])
        XCTAssertEqual(full?.route.count, 3)
        XCTAssertEqual(full?.display, "logan@100.90.45.11:2299 via me@jump.example, me@inner:2200")
        XCTAssertNil(SSHAddress("mini.local"))
        XCTAssertNil(SSHAddress("https://mini.local"))
        XCTAssertNil(SSHAddress("@mini.local"))
        XCTAssertNil(SSHAddress("logan@"))
        XCTAssertNil(SSHAddress("logan@mini:port"))
        XCTAssertNil(SSHAddress("logan@mini?via=nobody"))
        XCTAssertEqual(SSHAddress.hostKeySetting(SSHAddress.Hop(user: "logan", host: "mini", port: 22)), "ssh.hostkey.logan@mini:22")
    }

    /// Signing in connects as the user with no host key the first time,
    /// keeps the one seen, reaches the server's socket file (the command
    /// run there) and says hello through it, no password asked; the next
    /// sign-in offers the kept key and closes the earlier connection.
    func testTheFirstSignInKeepsTheHostKeyAndTheNextOffersIt() async throws {
        let server = VisorAgentServer(record: record())
        let name = try await server.authenticate(record())
        XCTAssertEqual(name, "Mini")
        XCTAssertEqual(ssh.connects.count, 1)
        XCTAssertEqual(ssh.connects[0].route, [VisorSSHHop(user: "logan", host: "mini.local", port: 22)])
        XCTAssertEqual(ssh.connects[0].hostKeys, [nil])
        XCTAssertEqual(settings.kept(key: "ssh.hostkey.logan@mini.local:22"), "ssh-ed25519 AAAAhost mini")
        XCTAssertEqual(ssh.sessions[0].attached, ["nc -U ~/.visor/server.sock"])
        XCTAssertEqual(ssh.sessions[0].forwarded, [], "the port is not needed")
        XCTAssertEqual(http.urls, ["http://127.0.0.1:60001/api/hello"])

        _ = try await server.authenticate(record())
        XCTAssertEqual(ssh.connects[1].hostKeys, ["ssh-ed25519 AAAAhost mini"])
        XCTAssertTrue(ssh.sessions[0].closed, "the earlier connection is closed before the next")
        XCTAssertFalse(ssh.sessions[1].closed)
    }

    /// A server that does not serve its socket file (SSH clients not let
    /// in without a password, an older server, no `nc`) is reached at its
    /// port on the computer's loopback instead, with the password.
    func testAServerWithoutTheSocketFileIsReachedAtItsPort() async throws {
        http.kill(port: 60001)
        let server = VisorAgentServer(record: record())
        let name = try await server.authenticate(record())
        XCTAssertEqual(name, "Mini")
        XCTAssertEqual(ssh.sessions[0].attached, ["nc -U ~/.visor/server.sock"])
        XCTAssertEqual(ssh.sessions[0].forwarded, [7433])
        XCTAssertEqual(http.urls, ["http://127.0.0.1:60001/api/hello", "http://127.0.0.1:54321/api/hello"])
        XCTAssertEqual(http.bearers.last, "pw")
        XCTAssertEqual(ssh.sessions.count, 1, "the same connection carries the port")
    }

    /// Through jump hosts, every hop is connected in order and every
    /// hop's key kept under its own name.
    func testJumpHostsAreOnTheWayAndEachKeyIsKept() async throws {
        ssh.hostKeysGiven = ["ssh-ed25519 AAAAjump", "ssh-ed25519 AAAAhost mini"]
        let server = VisorAgentServer(record: record("logan@10.0.0.2?via=logan@jump.example:2200"))
        _ = try await server.authenticate(record("logan@10.0.0.2?via=logan@jump.example:2200"))
        XCTAssertEqual(ssh.connects[0].route, [VisorSSHHop(user: "logan", host: "jump.example", port: 2200), VisorSSHHop(user: "logan", host: "10.0.0.2", port: 22)])
        XCTAssertEqual(ssh.connects[0].hostKeys, [nil, nil])
        XCTAssertEqual(settings.kept(key: "ssh.hostkey.logan@jump.example:2200"), "ssh-ed25519 AAAAjump")
        XCTAssertEqual(settings.kept(key: "ssh.hostkey.logan@10.0.0.2:22"), "ssh-ed25519 AAAAhost mini")
    }

    /// A computer whose host key changed is refused with a message; one
    /// that refuses the device's key says so (another path may let the
    /// device in, and authorize its key); a host with no SSH says so;
    /// nothing is said over HTTP in any case.
    func testWhatSSHRefusesIsSaidAsTheConnectionSaysIt() async throws {
        let server = VisorAgentServer(record: record())
        ssh.failure = .hostKeyChanged
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("host key"), text)
        }
        ssh.failure = .keyRefused
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("SSH key"), "another path may let the device in: \(text)")
        }
        ssh.failure = .unreachable("connection refused")
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("connection refused"), text)
        }
        XCTAssertTrue(http.urls.isEmpty, "nothing said over HTTP")
        VisorHost.ssh = nil
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("cannot reach"), text)
        }
    }

    /// Closing the channel closes the SSH connection with it; a plain
    /// address never touches SSH.
    func testClosingTheChannelClosesTheConnection() async throws {
        let server = VisorAgentServer(record: record())
        _ = try await server.authenticate(record())
        server.closeChannel()
        XCTAssertTrue(ssh.sessions[0].closed)
        XCTAssertNil(server.address, "no tunnel, no address")

        let plain = VisorAgentServer(record: record("http://10.0.0.2:7433"))
        _ = try await plain.authenticate(record("http://10.0.0.2:7433"))
        XCTAssertEqual(ssh.connects.count, 1)
        XCTAssertEqual(http.urls.last, "http://10.0.0.2:7433/api/hello")
    }
}
