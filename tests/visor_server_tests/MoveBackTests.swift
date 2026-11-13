// A session moved to a runner, back on this computer: on its own
// conversation, its folder here, a notice saying why; refused for one that
// runs here already, or whose conversation isn't known.

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
        #expect(record.notice == "Back on this computer: the clone failed")
        #expect(!record.info.skipPermissions, "prompts skipped only in a container: asked again here")
    }

    @Test func oneThatRunsHereOrWhoseConversationIsUnknownIsRefused() {
        server.takeDriven(SessionInfo(id: "m2", agent: .claude, cwd: "/tmp", title: "Moved", created: 0), process: RunnerAgent())
        #expect(!took(server.moveBack("m2", resume: "", cwd: "/tmp", why: "")), "no conversation to carry on")
        #expect(!took(server.moveBack("nobody", resume: "c", cwd: "/tmp", why: "")))
        _ = server.moveBack("m2", resume: "c-2", cwd: "/tmp", why: "test")
        #expect(!took(server.moveBack("m2", resume: "c-2", cwd: "/tmp", why: "again")), "it runs here already")
    }
}
}
