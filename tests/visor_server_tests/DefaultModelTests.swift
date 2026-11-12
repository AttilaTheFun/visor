// A session started with no model chosen runs the default it shows (the
// catalog's, this computer's agent's own), said explicitly: the same agent
// signed in another way (a container's long-lived token) may take another
// model for its default.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

@MainActor
private final class ModelAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }

    init() { (events, _) = AsyncStream.makeStream() }

    func send(_ text: String) throws {}
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async {}
}

private final class DefaultingHarness: AgentHarness {
    let kind = AgentKind.claude
    let tool = "claude"

    func catalog() -> AgentCatalog { AgentCatalog(agent: kind, models: [], defaultModel: "opus") }
    func transcript(id: String, cwd: String, limit: Int) -> [TranscriptEntry] { [] }
    func adoptHistory(id: String, cwd: String) {}

    @MainActor func makeProcess(cwd: String, skipPermissions: Bool, resume: String?) -> AgentProcess { ModelAgent() }
}

extension ServerTests {
@Suite @MainActor final class DefaultModelTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-default-model-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7989)
        server.harnesses = AgentHarnesses([DefaultingHarness()])
    }

    isolated deinit {
        server.stop()
    }

    @Test func testNoModelChosenRunsTheDefaultItShows() {
        let info = SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "S", created: 0)
        #expect(server.makeProcess(info, resume: nil).model == "opus")
    }

    @Test func testAChosenModelRunsAsChosen() {
        let info = SessionInfo(id: "S", agent: .claude, cwd: "/tmp", title: "S", model: "sonnet", created: 0)
        #expect(server.makeProcess(info, resume: nil).model == "sonnet")
    }
}
}
