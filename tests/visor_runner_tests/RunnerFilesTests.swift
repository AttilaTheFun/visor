// What the Runner's agent and its commands share (docs/co-tenancy.md): the
// secrets file, this user's alone and seen by both, and `runner.json`.

import Foundation
import VisorRunner
import Testing

@Suite final class RunnerFilesTests {
    private var folder: URL!

    init() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-files-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func testTheSecretsFileIsThisUsersAloneAndSeenByBoth() throws {
        let file = folder.appendingPathComponent("runner-secrets.json")
        let command = FileRunnerSecrets(file: file), agent = FileRunnerSecrets(file: file)
        command.set("mcp gh API_KEY", "k1")
        agent.set("proxy-server Builds token", "t1")
        #expect(agent.value("mcp gh API_KEY") == "k1")
        #expect(command.value("proxy-server Builds token") == "t1")
        command.set("mcp gh API_KEY", nil)
        #expect(agent.value("mcp gh API_KEY") == nil)
        command.set("mcp shireworks API_KEY", "")
        #expect(agent.value("mcp shireworks API_KEY") == nil, "empty is none")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue) == 0o600)
    }

    @Test func testTheConfigReadsBackAndFieldsLeftOutAreDefaults() throws {
        let config = RunnerConfig(mcpPort: 7539, endpoints: [.init(name: "gh", url: "http://127.0.0.1:7450/mcp", headers: ["X-A": "1"],
                                                                   secretHeaders: ["Authorization"])], servers: ["Builds"])
        try config.write(folder)
        #expect(RunnerConfig.read(folder) == config)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("runner.json"))
        #expect(RunnerConfig.read(folder) == RunnerConfig())
    }

    /// A server's token is made once and kept; only the servers listed get through.
    @Test func testEachServerHasATokenOfItsOwn() {
        let secrets = MemorySecrets()
        let builds = ProxyTokens.token(for: "Builds", in: secrets)
        #expect(builds.count == 64)
        #expect(ProxyTokens.token(for: "Builds", in: secrets) == builds, "made once")
        let other = ProxyTokens.token(for: "Other", in: secrets)
        #expect(other != builds)
        #expect(ProxyTokens.admits(builds, servers: ["Builds"], in: secrets))
        #expect(!ProxyTokens.admits(other, servers: ["Builds"], in: secrets), "a server not listed")
        #expect(!ProxyTokens.admits("", servers: ["Builds"], in: secrets))
    }
}
