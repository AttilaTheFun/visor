// What the Runner's agent and its commands share (docs/co-tenancy.md): the
// secrets file, this user's alone and seen by both, and `runner.json`.

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
        let command = FileRunnerSecrets(file: file), agent = FileRunnerSecrets(file: file)
        command.set("mcp gh API_KEY", "k1")
        agent.set("proxy-server Builds token", "t1")
        XCTAssertEqual(agent.value("mcp gh API_KEY"), "k1")
        XCTAssertEqual(command.value("proxy-server Builds token"), "t1")
        command.set("mcp gh API_KEY", nil)
        XCTAssertNil(agent.value("mcp gh API_KEY"))
        command.set("mcp oss API_KEY", "")
        XCTAssertNil(agent.value("mcp oss API_KEY"), "empty is none")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testTheConfigReadsBackAndFieldsLeftOutAreDefaults() throws {
        let config = RunnerConfig(mcpPort: 7539, endpoints: [.init(name: "gh", url: "http://127.0.0.1:7450/mcp", headers: ["X-A": "1"],
                                                                   secretHeaders: ["Authorization"])], servers: ["Builds"])
        try config.write(folder)
        XCTAssertEqual(RunnerConfig.read(folder), config)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("runner.json"))
        XCTAssertEqual(RunnerConfig.read(folder), RunnerConfig())
    }

    /// A server's token is made once and kept; only the servers listed get through.
    func testEachServerHasATokenOfItsOwn() {
        let secrets = MemorySecrets()
        let builds = ProxyTokens.token(for: "Builds", in: secrets)
        XCTAssertEqual(builds.count, 64)
        XCTAssertEqual(ProxyTokens.token(for: "Builds", in: secrets), builds, "made once")
        let other = ProxyTokens.token(for: "Other", in: secrets)
        XCTAssertNotEqual(other, builds)
        XCTAssertTrue(ProxyTokens.admits(builds, servers: ["Builds"], in: secrets))
        XCTAssertFalse(ProxyTokens.admits(other, servers: ["Builds"], in: secrets), "a server not listed")
        XCTAssertFalse(ProxyTokens.admits("", servers: ["Builds"], in: secrets))
    }
}
