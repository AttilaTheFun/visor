// A server reached over SSH: the record's `user@host[:port]`, a
// connection with the device's key through the host's SSH, the
// computer's host key kept the first time and compared after, a port
// forwarded to the server's loopback, and the HTTP sign-in through it.
// What SSH refuses is said as the connection says it: a changed host
// key as a message, a refused key as a sign-in to redo.

import Foundation
@testable import VisorClient
import VisorProtocol
import Synchronization
import VisorServices
import XCTest

/// SSH as the test scripts it: every connect is recorded, and answers a
/// session or fails as told.
@MainActor
final class ScriptedSSH: VisorSSHService {
    var connects: [(user: String, host: String, port: Int, hostKey: String?)] = []
    var failure: VisorSSHError?
    var hostKeyGiven = "ssh-ed25519 AAAAhost mini"
    var sessions: [ScriptedSSHSession] = []

    func publicKey() -> String { "ssh-ed25519 AAAAdevice visor" }

    func connect(user: String, host: String, port: Int, hostKey: String?) async throws -> any VisorSSHSession {
        connects.append((user, host, port, hostKey))
        if let failure { throw failure }
        let session = ScriptedSSHSession(hostKey: hostKeyGiven)
        sessions.append(session)
        return session
    }
}

@MainActor
final class ScriptedSSHSession: VisorSSHSession {
    let hostKey: String
    var forwarded: [Int] = []
    var closed = false
    init(hostKey: String) { self.hostKey = hostKey }
    func forward(toPort port: Int) async throws -> Int { forwarded.append(port); return 54321 }
    func close() { closed = true }
}

/// HTTP that records where it was asked, and answers hello.
final class RecordingHTTP: VisorHTTPService {
    private let asked = Mutex<[String]>([])
    var urls: [String] { asked.withLock { $0 } }
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        asked.withLock { $0.append(url) }
        if url.hasSuffix("/api/hello") { return Envelope.hello(host: "Mini", login: "", token: "tok-1").encoded() }
        return Envelope(type: "reply").encoded()
    }
    func status(of error: Error) -> Int? { nil }
}

@MainActor
final class SSHAgentServerTests: XCTestCase {
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
        AgentServerRecord(name: "Mini", address: address, secret: "pw", provider: SSHAgentServerProvider.name)
    }

    /// The address is a user and a host, with a port when one is given;
    /// an `ssh://` prefix and the spaces around are not minded.
    func testTheAddressIsUserAtHostWithAPort() {
        XCTAssertEqual(SSHAgentServer.Address("logan@mini.local").map { [$0.user, $0.host, String($0.port)] }, ["logan", "mini.local", "22"])
        XCTAssertEqual(SSHAgentServer.Address(" ssh://logan@100.90.45.11:2299\n").map { [$0.user, $0.host, String($0.port)] }, ["logan", "100.90.45.11", "2299"])
        XCTAssertNil(SSHAgentServer.Address("mini.local"))
        XCTAssertNil(SSHAgentServer.Address("@mini.local"))
        XCTAssertNil(SSHAgentServer.Address("logan@"))
    }

    /// Signing in connects as the user with no host key the first time,
    /// keeps the one seen, forwards the server's port and says hello
    /// through it; the next sign-in offers the kept key.
    func testTheFirstSignInKeepsTheHostKeyAndTheNextOffersIt() async throws {
        let server = SSHAgentServer(record: record())
        let name = try await server.authenticate(record())
        XCTAssertEqual(name, "Mini")
        XCTAssertEqual(ssh.connects.count, 1)
        XCTAssertEqual(ssh.connects[0].user, "logan")
        XCTAssertEqual(ssh.connects[0].host, "mini.local")
        XCTAssertEqual(ssh.connects[0].port, 22)
        XCTAssertNil(ssh.connects[0].hostKey)
        XCTAssertEqual(settings.get(key: "ssh.hostkey.logan@mini.local:22"), "ssh-ed25519 AAAAhost mini")
        XCTAssertEqual(ssh.sessions[0].forwarded, [7433])
        XCTAssertEqual(http.urls, ["http://127.0.0.1:54321/api/hello"])

        _ = try await server.authenticate(record())
        XCTAssertEqual(ssh.connects[1].hostKey, "ssh-ed25519 AAAAhost mini")
        XCTAssertTrue(ssh.sessions[0].closed, "the earlier connection is closed before the next")
    }

    /// A computer whose host key changed is refused with a message; one
    /// that refuses the device's key is a sign-in to redo.
    func testWhatSSHRefusesIsSaidAsTheConnectionSaysIt() async throws {
        let server = SSHAgentServer(record: record())
        ssh.failure = .hostKeyChanged
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("host key has changed"), text)
        }
        ssh.failure = .keyRefused
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.needsAuthentication {}
        ssh.failure = .unreachable("connection refused")
        do {
            _ = try await server.authenticate(record())
            XCTFail("signed in")
        } catch AgentServerError.message(let text) {
            XCTAssertTrue(text.contains("connection refused"), text)
        }
        // An address that is not one.
        do {
            _ = try await server.authenticate(record("mini.local"))
            XCTFail("signed in")
        } catch AgentServerError.message {}
        XCTAssertTrue(http.urls.isEmpty, "nothing said over HTTP")
    }

    /// Closing the channel closes the SSH connection with it.
    func testClosingTheChannelClosesTheConnection() async throws {
        let server = SSHAgentServer(record: record())
        _ = try await server.authenticate(record())
        server.closeChannel()
        XCTAssertTrue(ssh.sessions[0].closed)
    }

    /// The provider is offered where the host has SSH, and not elsewhere;
    /// a record of its kind still resolves either way.
    func testTheProviderIsOfferedWhereTheHostHasSSH() {
        XCTAssertTrue(AgentServerProviders.all.contains { $0.id == "ssh" })
        VisorHost.ssh = nil
        XCTAssertFalse(AgentServerProviders.all.contains { $0.id == "ssh" })
        XCTAssertEqual(AgentServerProviders.provider(for: record().provider)?.id, "ssh")
    }
}
