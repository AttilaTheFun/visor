// A server's sign-in over the host's services: `hello` over HTTP first —
// let in on the password, refused with 401 otherwise — then the socket,
// logged in with the token hello gave. A 401 is the server asking for a
// password, which the connection shows and does not retry.

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

    /// Whether a socket opens at all (a path that carries no WebSocket
    /// leaves it hanging).
    var opens = true

    func open(url: String) -> Int32 {
        opened.append(url)
        if opens { push("open") }
        return Int32(opened.count)
    }

    /// A Mac whose server takes the socket and never answers.
    var silent = false

    func send(id: Int32, text: String) {
        sent.append(text)
        if silent { return }
        if let envelope = Envelope.decode(text), envelope.type == "login" {
            let reply: Envelope = envelope.token == "tok-1" ? .welcome(host: "Scripted Mac", sessions: [], catalogs: []) : .error("Wrong password")
            push("message " + reply.encoded())
        }
        if let envelope = Envelope.decode(text), envelope.type == "ping", answersPings {
            push("message " + (knowsPings ? Envelope.pong() : Envelope.error("Unknown message ping")).encoded())
        }
    }

    func disconnect(id: Int32) { push("close closed") }

    func next(id: Int32) async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    /// The pauses asked for, each held until the test lets it go.
    private(set) var pauses: [Int32] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Whether a ping is answered (a Mac that is there) or not.
    var answersPings = true
    /// A Mac from before the heartbeat complains about the ping instead.
    var knowsPings = true

    func delay(milliseconds: Int32) async {
        pauses.append(milliseconds)
        await withCheckedContinuation { held.append($0) }
    }

    /// Lets the oldest pause of this length end.
    func elapse(_ milliseconds: Int32) {
        guard let index = pauses.firstIndex(of: milliseconds) else { return }
        pauses.remove(at: index)
        held.remove(at: index).resume()
    }

    private func push(_ event: String) {
        if let waiting { self.waiting = nil; waiting.resume(returning: event) } else { queue.append(event) }
    }
}

@MainActor
final class SignInTests: XCTestCase {
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
        XCTAssertEqual(socket.opened, ["wss://mac.example/"])
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

    /// Every 16 s the channel is pinged; an answer within 8 s keeps it.
    func testAHeartbeatThatIsAnsweredKeepsTheChannel() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        socket.elapse(4000)     // the login was answered in time
        await settle()
        for _ in 0..<2 {
            socket.elapse(16_000)
            await settle()
            socket.elapse(8000)
            await settle()
        }
        XCTAssertEqual(socket.sent.compactMap { Envelope.decode($0) }.filter { $0.type == "ping" }.count, 2)
        XCTAssertEqual(host.state, .connected)
    }

    /// A Mac from before the heartbeat answers a ping with a complaint:
    /// that is an answer, and is not shown as an error.
    func testAnOlderMacsComplaintIsAnAnswer() async {
        socket.knowsPings = false
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        socket.elapse(4000)
        await settle()
        socket.elapse(16_000)
        await settle()
        socket.elapse(8000)
        await settle()
        XCTAssertEqual(host.state, .connected)
    }

    /// No answer within 8 s of a ping: the channel is dropped, and the
    /// connection starts its retries.
    func testAHeartbeatThatIsNotAnsweredDropsTheChannel() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        socket.elapse(4000)
        await settle()
        socket.answersPings = false
        socket.elapse(16_000)
        await settle()
        socket.elapse(8000)
        await settle()
        XCTAssertEqual(host.state, .offline("No answer to a heartbeat"))
        XCTAssertTrue(socket.pauses.contains(2000), "the first retry is two seconds off")
    }

    /// Asked outright (the app back in front), a channel that answers the
    /// ping is kept, and one that does not within 1 s is opened afresh.
    func testAChannelIsVerifiedWhenTheAppComesBack() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        host.resume()
        await settle()
        socket.elapse(1000)
        await settle()
        XCTAssertEqual(socket.opened.count, 1, "it answered")

        socket.answersPings = false
        host.resume()
        await settle()
        socket.elapse(1000)
        await settle()
        XCTAssertEqual(socket.opened.count, 2, "it did not: a new socket")
        XCTAssertEqual(host.state, .connected)
    }

    /// A socket that opens and then says nothing — the login never
    /// answered — is dropped after 8 s rather than waited on for ever.
    func testALoginThatIsNotAnsweredDropsTheChannel() async {
        hello(.success(Envelope.hello(host: "Mac", login: "", token: "tok-1").encoded()))
        socket.silent = true
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connecting)
        socket.elapse(4000)
        await settle()
        XCTAssertEqual(host.state, .offline("No answer to the login"))
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
