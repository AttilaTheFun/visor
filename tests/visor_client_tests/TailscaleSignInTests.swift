// The Mac's sign-in over the host's services: `hello` over HTTP first —
// let in on the network's word or the password, refused with 401
// otherwise — then the socket, logged in with the token hello gave. A
// 401 is the Mac asking for a password, which the connection shows and
// does not retry.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// HTTP as the test scripts it: hello answers a body or fails with a
/// status. Fixed once made; a test that changes its mind installs another.
struct ScriptedHTTP: VisorHTTPService {
    let hello: Result<String, ScriptedFailure>
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        if url.hasSuffix("/api/hello") { return try hello.get() }
        return Envelope(type: "reply").encoded()
    }
    func status(of error: Error) -> Int? { (error as? ScriptedFailure)?.status }
}

struct ScriptedFailure: Error { let status: Int }

/// One socket that opens at once and answers a login it accepts with welcome.
@MainActor
final class ScriptedSocket: VisorSocketService {
    var opened: [String] = []
    var sent: [String] = []
    private var queue: [String] = []
    private var waiting: CheckedContinuation<String, Error>?

    func open(url: String) -> Int32 {
        opened.append(url)
        push("open")
        return Int32(opened.count)
    }

    func send(id: Int32, text: String) {
        sent.append(text)
        if let envelope = Envelope.decode(text), envelope.type == "login" {
            let reply: Envelope = envelope.token == "tok-1" ? .welcome(host: "Scripted Mac", sessions: [], catalogs: []) : .error("Wrong password")
            push("message " + reply.encoded())
        }
    }

    func disconnect(id: Int32) { push("close closed") }

    func next(id: Int32) async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func delay(milliseconds: Int32) async {}

    private func push(_ event: String) {
        if let waiting { self.waiting = nil; waiting.resume(returning: event) } else { queue.append(event) }
    }
}

@MainActor
final class TailscaleSignInTests: XCTestCase {
    private var socket: ScriptedSocket!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        hello(.success(Envelope.hello(host: "Scripted Mac", login: "owner@example.com", token: "tok-1").encoded()))
        socket = ScriptedSocket()
        VisorHost.socket = socket
        VisorHost.settings = MemorySettings()
    }

    private func hello(_ answer: Result<String, ScriptedFailure>) {
        VisorHost.http = ScriptedHTTP(hello: answer)
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func testHelloThenTokenLogin() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.record.name, "Scripted Mac")
        XCTAssertEqual(socket.opened, ["wss://mac.example"])
        let login = socket.sent.compactMap { Envelope.decode($0) }.first { $0.type == "login" }
        XCTAssertEqual(login?.token, "tok-1")
        XCTAssertEqual(login?.password, "")
    }

    func testRefusedHelloAsksForAPassword() async {
        hello(.failure(ScriptedFailure(status: 401)))
        let host = AgentServerConnection(record: AgentServerRecord(name: "Other", address: "other.example"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .needsAuthentication)
        // No socket was opened, and nothing keeps retrying.
        XCTAssertEqual(socket.opened, [])

        // With the password saved, the Mac lets it in.
        hello(.success(Envelope.hello(host: "Other Mac", login: "owner@example.com", token: "tok-1").encoded()))
        host.update { $0.secret = "pearl-grove" }
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        let login = socket.sent.compactMap { Envelope.decode($0) }.first { $0.type == "login" }
        XCTAssertEqual(login?.password, "pearl-grove")
    }

    /// The socket's login refused (a token gone stale) reads as a refusal,
    /// not an outage.
    func testARefusedLoginAsksForAPassword() async {
        hello(.success(Envelope.hello(host: "Mac", login: "", token: "stale").encoded()))
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .needsAuthentication)
    }
}
