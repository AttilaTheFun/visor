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
