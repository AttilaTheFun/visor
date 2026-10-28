// A Visor server signed in to by several paths at once: the first at once,
// the next 400 ms later unless one has answered (or at once when the first
// has failed), the first to get in taken. A 401 from one path is the
// answer only when no other gets in.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// HTTP whose hello answers by host: a body, a failure, or nothing at all.
struct RacingHTTP: VisorHTTPService {
    let answers: [String: Result<String, ScriptedFailure>]
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        guard url.hasSuffix("/api/hello") else { return Envelope(type: "reply").encoded() }
        guard let answer = answers.first(where: { url.hasPrefix($0.key) })?.value else {
            // Not there: no answer, ever.
            while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }
        return try answer.get()
    }
    func status(of error: Error) -> Int? { (error as? ScriptedFailure)?.status }
    func body(of error: Error) -> String? { (error as? ScriptedFailure)?.body }
}

@MainActor
final class PathRaceTests: XCTestCase {
    private var socket: ScriptedSocket!
    private let welcome = Result<String, ScriptedFailure>.success(Envelope.hello(host: "Scripted Mac", login: "", token: "tok-1").encoded())
    private let record = AgentServerRecord(name: "Mini", address: "http://a:7433", secret: "pw", paths: ["http://b:7433"])

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        socket = ScriptedSocket()
        VisorHost.socket = socket
        VisorHost.settings = MemorySettings()
        VisorHost.network = nil
        VisorHost.ssh = nil
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// The first path says nothing: the second starts beside it after
    /// 400 ms and is taken, without waiting out the first's 5 s.
    func testASilentPathCostsAMoment() async {
        VisorHost.http = RacingHTTP(answers: ["http://b:7433": welcome])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connecting)
        socket.elapse(AgentServerConnection.headStart)
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://b:7433")
        XCTAssertEqual(host.record.lastPath, "http://b:7433")
    }

    /// The first path refused at once: the second starts then, not after
    /// the stagger.
    func testARefusedPathStartsTheNextAtOnce() async {
        VisorHost.http = RacingHTTP(answers: ["http://a:7433": .failure(ScriptedFailure(status: 0)), "http://b:7433": welcome])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://b:7433")
    }

    /// One path asks for a password and another lets the device in: in.
    /// Every path asking, or failing: then it is the password.
    func testAPasswordAskedForCountsOnlyIfNothingGetsIn() async {
        VisorHost.http = RacingHTTP(answers: ["http://a:7433": .failure(ScriptedFailure(status: 401)), "http://b:7433": welcome])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://b:7433")

        VisorHost.http = RacingHTTP(answers: ["http://a:7433": .failure(ScriptedFailure(status: 401)),
                                              "http://b:7433": .failure(ScriptedFailure(status: 0))])
        let locked = AgentServerConnection(record: AgentServerRecord(name: "Mini", address: "http://a:7433", paths: ["http://b:7433"]))
        locked.connect()
        await settle()
        XCTAssertEqual(locked.state, .needsAuthentication)
    }

    /// This computer's own paths are down a moment (its server starting
    /// again), and a path it has by mistake reaches another computer, which
    /// refuses: that is not this computer asking for a password. The path
    /// goes, and this computer is tried again and got into.
    func testAnotherComputersRefusalIsNotThisOnesPassword() async {
        var mini = record
        mini.serverID = "mini"
        VisorHost.http = RacingHTTP(answers: ["http://a:7433": .failure(ScriptedFailure(status: 0)),
                                              "http://b:7433": .failure(ScriptedFailure(status: 401, body: #"{"error":"wrong password","id":"macbook"}"#))])
        let host = AgentServerConnection(record: mini)
        host.connect()
        await settle()
        XCTAssertNotEqual(host.state, .needsAuthentication, "another computer's refusal taken for this one's")
        XCTAssertFalse(host.record.paths.contains("http://b:7433"), "the other computer's path kept")

        VisorHost.http = RacingHTTP(answers: ["http://a:7433": welcome])
        for _ in 0..<4 where host.state != .connected {
            socket.elapse(2000)
            await settle()
        }
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.path, "http://a:7433")
    }

    /// This computer's own refusal is still its own: it asks for a password.
    func testThisComputersRefusalStillAsksForThePassword() async {
        var mini = AgentServerRecord(name: "Mini", address: "http://a:7433", paths: ["http://b:7433"])
        mini.serverID = "mini"
        VisorHost.http = RacingHTTP(answers: ["http://a:7433": .failure(ScriptedFailure(status: 401, body: #"{"error":"wrong password","id":"mini"}"#)),
                                              "http://b:7433": .failure(ScriptedFailure(status: 0))])
        let host = AgentServerConnection(record: mini)
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .needsAuthentication)
    }

    /// A round overtaken by a sign-in begun since starts nothing more: only
    /// the new round goes on to the next path.
    func testAnOvertakenRoundStartsNothingMore() async {
        VisorHost.http = RacingHTTP(answers: ["http://b:7433": welcome])
        ConnectionLog.shared.clear()
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        host.disconnect()
        host.connect()
        await settle()
        socket.elapse(AgentServerConnection.headStart)
        await settle()
        let also = "also signing in by http://b:7433"
        XCTAssertFalse(ConnectionLog.shared.text.contains(also), "the overtaken round went on")
        socket.elapse(AgentServerConnection.headStart)
        await settle()
        XCTAssertEqual(ConnectionLog.shared.text.components(separatedBy: also).count - 1, 1)
        XCTAssertEqual(host.state, .connected)
    }

    /// No path answers: each is given up after its time, and the round
    /// ends as one failed try, followed by the schedule.
    func testNoPathAnsweringEndsTheRound() async {
        VisorHost.http = RacingHTTP(answers: [:])
        let host = AgentServerConnection(record: record)
        host.connect()
        await settle()
        socket.elapse(AgentServerConnection.headStart)
        await settle()
        socket.elapse(AgentServerConnection.signInTimeout)
        socket.elapse(AgentServerConnection.signInTimeout)
        await settle()
        guard case .offline = host.state else { return XCTFail("not offline: \(host.state)") }
        XCTAssertTrue(socket.pauses.contains(2000), "the first retry's wait")
    }
}
