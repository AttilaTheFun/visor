// A session moved to a runner, back on this computer: on its own
// conversation, its folder here, a notice saying why; refused for one that
// runs here already, or whose conversation isn't known. A runner's agent
// whose wrapper can't hand the session back (protocol 1), or doesn't within
// the wait, leaves the session on the conversation it had before it moved,
// and the notice says its turns there weren't returned. REST's moveBack
// takes `{}`: the conversation known here.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// A runner's agent, as the server holds it: told to stop when the session
/// comes back.
@MainActor
private final class RunnerAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    private(set) var stopped = false

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func interrupt() {}
    func stop() { stopped = true }
    func end(within deadline: Duration) async { stopped = true }
}

/// A runner's agent whose wrapper takes a hand-back (protocol 2), asked
/// to hand back and never returning anything.
@MainActor
private final class SilentHandingBack: HandingBackProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var takesHandBack: Bool { true }
    private(set) var handedBack = 0
    private(set) var stopped = false

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func interrupt() {}
    func stop() { stopped = true }
    func end(within deadline: Duration) async { stopped = true }
    func handBack() { handedBack += 1 }
}

/// Whether the server took it.
private func took(_ result: Result<Void, AgentJobRefusal>) -> Bool {
    if case .success = result { return true }
    return false
}

extension ServerTests {
@Suite @MainActor final class MoveBackTests {
    private var server: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-move-back-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7992)
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aMovedSessionComesBackOnItsConversation() throws {
        let runner = RunnerAgent()
        let record = server.takeDriven(SessionInfo(id: "m1", agent: .claude, cwd: "/Volumes/Sessions/Claude/a1", title: "Moved", created: 0),
                                       process: runner)
        #expect(record.driven)
        record.setPermissions(skip: true)
        let result = server.moveBack("m1", resume: "c-1", cwd: "/Users/a/Developer", why: "the clone failed")
        #expect(took(result))
        #expect(runner.stopped, "the runner's agent is told to stop")
        #expect(!record.driven)
        #expect(record.info.cwd == "/Users/a/Developer")
        #expect(record.process !== runner)
        #expect(record.notice?.hasPrefix("Back on this computer: the clone failed (") == true, "dated")
        #expect(!record.info.skipPermissions, "prompts skipped only in a container: asked again here")
    }

    @Test func oneThatRunsHereOrWhoseConversationIsUnknownIsRefused() {
        server.takeDriven(SessionInfo(id: "m2", agent: .claude, cwd: "/tmp", title: "Moved", created: 0), process: RunnerAgent())
        #expect(!took(server.moveBack("m2", resume: "", cwd: "/tmp", why: "")), "no conversation to carry on")
        #expect(!took(server.moveBack("nobody", resume: "c", cwd: "/tmp", why: "")))
        _ = server.moveBack("m2", resume: "c-2", cwd: "/tmp", why: "test")
        #expect(!took(server.moveBack("m2", resume: "c-2", cwd: "/tmp", why: "again")), "it runs here already")
    }

    /// A session whose runner's agent had started there.
    private func moved(_ id: String, process: AgentProcess) -> SessionRecord {
        let record = server.takeDriven(SessionInfo(id: id, agent: .claude, cwd: "/Volumes/Sessions/Claude/a1", title: "Moved", created: 0),
                                       process: process)
        record.move = AgentJobMove(agent: "a1", session: id, title: "Moved", resume: "c-before", cwd: "/tmp", runsOn: "container",
                                   conversation: "c-on-runner")
        return record
    }

    @Test func aProtocolOneWrapperIsToldToStopAndItsTurnsAreSaidNotReturned() throws {
        let runner = RunnerAgent()
        let record = moved("p1", process: runner)
        #expect(took(server.moveBack("p1", resume: "c-before", cwd: "/tmp", why: "moved back by request")))
        #expect(runner.stopped, "an older wrapper is told to stop")
        #expect(!record.driven && !server.isHandingBack("p1"), "back at once")
        #expect(record.process.resumeID == "c-before", "on the conversation it had before it moved")
        let notice = try #require(record.notice)
        #expect(notice.hasPrefix("Back on this computer: moved back by request. Its turns on the runner weren't returned ("))
    }

    @Test func aHandBackNotReturnedInTimeFallsBackWithANotice() async throws {
        server.handBackWait = .milliseconds(150)
        let runner = SilentHandingBack()
        let record = moved("t1", process: runner)
        #expect(took(server.moveBack("t1", resume: "c-before", cwd: "/tmp", why: "moved back by request")))
        #expect(runner.handedBack == 1, "a protocol-2 wrapper is asked to hand back")
        #expect(!runner.stopped, "and not told to stop")
        #expect(record.driven && server.isHandingBack("t1"), "the session waits for its conversation")
        #expect(record.info.agentState == .stopping)
        #expect(took(server.moveBack("t1", resume: "c-before", cwd: "/tmp", why: "again")), "asked again meanwhile: the same move back")
        #expect(runner.handedBack == 1)
        await server.handBackEnded("t1")
        #expect(!record.driven && !server.isHandingBack("t1"))
        #expect(runner.stopped, "given up on, its agent is told to stop")
        #expect(record.process.resumeID == "c-before")
        let notice = try #require(record.notice)
        #expect(notice.contains("Its turns on the runner weren't returned (its runner's agent didn't return it within 150 ms)"), "\(notice)")
    }

    @Test func restMoveBackTakesAnEmptyBody() async throws {
        let runner = RunnerAgent()
        let record = moved("r1", process: runner)
        var request = HTTPRequest(method: "POST", path: "/api/sessions/r1/moveBack", headers: [:], body: "{}")
        request.trusted = true
        let response: HTTPResponse = await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
        #expect(response.status == 200, "\(response.body)")
        #expect(!record.driven)
        #expect(record.process.resumeID == "c-before", "the conversation known here: the runner's own isn't on this computer")
        #expect(record.info.cwd == "/Volumes/Sessions/Claude/a1", "its folder as it is")

        // No move known, and nothing given: refused, as before.
        server.takeDriven(SessionInfo(id: "r2", agent: .claude, cwd: "/tmp", title: "Unknown", created: 0), process: RunnerAgent())
        var unknown = HTTPRequest(method: "POST", path: "/api/sessions/r2/moveBack", headers: [:], body: "{}")
        unknown.trusted = true
        let refused: HTTPResponse = await withCheckedContinuation { done in server.route(unknown) { done.resume(returning: $0) } }
        #expect(refused.status == 400)
    }
}
}
