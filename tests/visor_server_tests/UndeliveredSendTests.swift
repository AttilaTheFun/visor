// A message from a client that no agent has: said in the server's log, with
// why, as well as to the session. On 26 Nov 2026 the log said nothing of a
// send, taken or not, and what happened to the person's messages could only
// be pieced together from the system's records of its connections.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Synchronization
import Testing

/// An agent that writes down what it is sent, or can't be started.
@MainActor
private final class StubbornAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var said: [String] = []
    /// Why it can't be started, while it can't.
    var refusal: String?

    init() { (events, emit) = AsyncStream.makeStream() }

    func send(_ text: String) throws {
        if let refusal { throw AgentProcessError.spawnFailed(refusal) }
        said.append(text)
    }
    func start() throws {}
    func startsTurn(_ text: String) -> Bool { true }
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

/// The log's lines, as the platform's log (on any thread) writes them.
private final class Heard: Sendable {
    let lines = Mutex<[String]>([])
}

extension ServerTests {
@Suite @MainActor final class UndeliveredSendTests {
    private var server: VisorServer!
    /// What the server logged while the test ran.
    private let logged = Heard()

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-undelivered-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
    }

    /// The log heard from here on: in the test itself, as another suite's
    /// start puts the platform (and its log) back as it was.
    private func listen() {
        let logged = self.logged
        ServerPlatform.current.log = { line in logged.lines.withLock { $0.append(line) } }
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String, _ title: String, agent: StubbornAgent) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0), process: agent, entries: [])
    }

    private func said(_ words: String) -> Bool { logged.lines.withLock { $0.contains { $0.contains(words) } } }

    @Test func aMessageForNoSessionIsLogged() {
        listen()
        server.perform(.send(session: "gone4u2", text: "are you there?"), from: nil)
        #expect(said("a message was not taken: there is no session gone4u2 here"))
    }

    @Test func aMessageItsAgentCouldNotTakeIsLoggedAndTold() {
        listen()
        let agent = StubbornAgent()
        agent.refusal = "its host did not start"
        let session = record("m", "Manager", agent: agent)
        server.sessions = [session]
        server.perform(.send(session: "m", text: "ok images is migrating now"), from: nil)
        #expect(agent.said.isEmpty)
        #expect(said("a message to Manager (m) could not be handed to its agent: its host did not start"))
        #expect(session.info.busy == false, "not left working on a turn its agent never had")
    }

    /// A send asked again under its id, its first answer lost on the way
    /// back: taken once, and said in the log; another id is another send.
    @Test func aSendAskedAgainUnderItsIdIsTakenOnce() {
        listen()
        let agent = StubbornAgent()
        let session = record("m", "Manager", agent: agent)
        server.sessions = [session]
        var send = Envelope.send(session: "m", text: "ok images is migrating now")
        send.id = "sending-1"
        server.perform(send, from: nil)
        _ = session.apply(.busy(false))
        server.perform(send, from: nil)
        #expect(agent.said == ["ok images is migrating now"])
        #expect(said("came again (sending-1): it was taken the first time"))
        send.id = "sending-2"
        server.perform(send, from: nil)
        #expect(agent.said == ["ok images is migrating now", "ok images is migrating now"], "the same words again are a message of their own")
    }

    /// The ids are kept a while, and only so many.
    @Test func sendsIdsAreKeptForAWhile() {
        let session = record("m", "Manager", agent: StubbornAgent())
        let start = Date()
        #expect(session.takeSend("a", now: start))
        #expect(!session.takeSend("a", now: start.addingTimeInterval(60)))
        #expect(session.takeSend("a", now: start.addingTimeInterval(SessionRecord.sendsKeptFor + 1)), "forgotten after a while")
        for n in 0..<(SessionRecord.sendsKept + 10) { _ = session.takeSend("n\(n)", now: start.addingTimeInterval(SessionRecord.sendsKeptFor + 2)) }
        #expect(session.takenSends.count <= SessionRecord.sendsKept)
    }

    @Test func aMessageItsAgentTookIsNotLogged() {
        listen()
        let agent = StubbornAgent()
        let session = record("m", "Manager", agent: agent)
        server.sessions = [session]
        server.perform(.send(session: "m", text: "hello"), from: nil)
        #expect(agent.said == ["hello"])
        #expect(!said("could not be handed") && !said("was not taken"), "a send that goes through is not a line of its own")
    }
}
}
