import Foundation
import VisorProtocol
import XCTest
@testable import VisorServer

/// A kind of agent's environment file: its lines given to that kind's
/// sessions, a PATH put before the agent's own; none for a kind without one.
final class AgentEnvironmentFileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestPlatform.install()
    }

    func testAnAgentsFileIsItsSessionsEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-env-" + UUID().uuidString)
        let agents = folder.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "# Claude's GitHub App\nGIT_AUTHOR_NAME=Claude\nGIT_CONFIG_VALUE_0=\nGIT_CONFIG_VALUE_1=!/bin/agent-token credential claude\nPATH=/shims\n"
            .write(to: agents.appendingPathComponent("claude.env"), atomically: true, encoding: .utf8)
        let values = AgentEnvironmentFile.read(.claude, in: folder, base: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(values["GIT_AUTHOR_NAME"], "Claude")
        XCTAssertEqual(values["GIT_CONFIG_VALUE_0"], "", "an empty value is kept: it clears git's helpers before it")
        XCTAssertEqual(values["GIT_CONFIG_VALUE_1"], "!/bin/agent-token credential claude")
        XCTAssertEqual(values["PATH"], "/shims:/usr/bin:/bin")
        XCTAssertNil(values["# Claude's GitHub App"])
        XCTAssertEqual(AgentEnvironmentFile.read(.codex, in: folder, base: [:]), [:])
    }
}
