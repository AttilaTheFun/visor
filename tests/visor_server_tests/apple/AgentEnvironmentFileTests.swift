import Foundation
@testable import VisorAgent
import VisorProtocol
import Testing
@testable import VisorServer

/// A kind of agent's environment file: its lines given to that kind's
/// sessions, a PATH put before the agent's own; none for a kind without one.
extension ServerTests {
@Suite final class AgentEnvironmentFileTests {
    init() {
        super.setUp()
        TestPlatform.install()
    }

    @Test func testAnAgentsFileIsItsSessionsEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-env-" + UUID().uuidString)
        let agents = folder.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "# Claude's GitHub App\nGIT_AUTHOR_NAME=Claude\nGIT_CONFIG_VALUE_0=\nGIT_CONFIG_VALUE_1=!/bin/agent-token credential claude\nPATH=/shims\n"
            .write(to: agents.appendingPathComponent("claude.env"), atomically: true, encoding: .utf8)
        let values = AgentEnvironmentFile.read(.claude, in: folder, base: ["PATH": "/usr/bin:/bin"])
        #expect((values["GIT_AUTHOR_NAME"]) == "Claude")
        #expect((values["GIT_CONFIG_VALUE_0"]) == "", "an empty value is kept: it clears git's helpers before it")
        #expect((values["GIT_CONFIG_VALUE_1"]) == "!/bin/agent-token credential claude")
        #expect((values["PATH"]) == "/shims:/usr/bin:/bin")
        #expect((values["# Claude's GitHub App"]) == nil)
        #expect(AgentEnvironmentFile.read(.codex, in: folder, base: [:]) == [:])
    }
}
}
