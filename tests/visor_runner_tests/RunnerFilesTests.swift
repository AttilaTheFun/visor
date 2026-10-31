// What the menu bar app and the Runner's agent share (docs/co-tenancy.md):
// the secrets file, this user's alone and seen by both; `runner.json`; and
// the agents' sign-ins as the Runner keeps them.

import Foundation
import VisorRunner
import XCTest

final class RunnerFilesTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-files-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheSecretsFileIsThisUsersAloneAndSeenByBoth() throws {
        let file = folder.appendingPathComponent("runner-secrets.json")
        let app = FileRunnerSecrets(file: file), agent = FileRunnerSecrets(file: file)
        app.set("runner claudeToken", "t1")
        agent.set("container-server S1 password", "p1")
        XCTAssertEqual(agent.value("runner claudeToken"), "t1")
        XCTAssertEqual(app.value("container-server S1 password"), "p1")
        app.set("runner claudeToken", nil)
        XCTAssertNil(agent.value("runner claudeToken"))
        app.set("runner openrouterKey", "")
        XCTAssertNil(agent.value("runner openrouterKey"), "empty is none")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testTheConfigReadsBackAndFieldsLeftOutAreDefaults() throws {
        let config = RunnerConfig(mcpPort: 7539, endpoints: [.init(name: "gh", url: "http://127.0.0.1:7450/mcp", headers: ["X-A": "1"],
                                                                   secretHeaders: ["Authorization"])])
        try config.write(folder)
        XCTAssertEqual(RunnerConfig.read(folder), config)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("runner.json"))
        XCTAssertEqual(RunnerConfig.read(folder), RunnerConfig())
    }

    func testSignInsAreTheKeptTokenAndKeyAndTheMacsCodexFile() throws {
        let secrets = FileRunnerSecrets(file: folder.appendingPathComponent("runner-secrets.json"))
        secrets.set(ContainerServer.SignIns.claudeKey, "claude")
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("{\"codex\":2}".utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
        let kept = ContainerServer.SignIns.kept(in: secrets, home: home)
        XCTAssertEqual(kept, .init(claudeToken: "claude", openrouterKey: nil, codexAuth: Data("{\"codex\":2}".utf8)))
    }
}
