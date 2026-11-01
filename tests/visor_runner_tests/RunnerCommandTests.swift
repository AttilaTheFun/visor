// visor-runner-agent's commands (docs/co-tenancy.md): MCP servers set with
// their secret headers read from standard input and kept by the Runner
// alone; a Visor server added is given its settings, every MCP server at
// the proxy with its own token, and no secret.

import Foundation
import VisorRunner
import XCTest

final class RunnerCommandTests: XCTestCase {
    private var folder: URL!
    private var secrets: MemorySecrets!
    private var said: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-command-\(UUID().uuidString)", isDirectory: true)
        secrets = MemorySecrets()
        said = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String], input: [String] = []) -> Int32 {
        var lines = input[...]
        return RunnerCommand(folder: folder, secrets: secrets, input: { lines.popFirst() }, output: { self.said.append($0) }).run(arguments)
    }

    func testAnEndpointsSecretsAreReadFromInputAndKeptHereAlone() throws {
        XCTAssertEqual(run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--header", "CLIENT_ID=$SESSION_ID", "--secret", "API_KEY"],
                           input: ["gh-key\n"]), 0)
        let config = try XCTUnwrap(RunnerConfig.read(folder))
        XCTAssertEqual(config.endpoints, [.init(name: "gh", url: "http://127.0.0.1:7470/mcp", headers: ["CLIENT_ID": "$SESSION_ID"],
                                                secretHeaders: ["API_KEY"])])
        XCTAssertEqual(secrets.value(ProxyTokens.secretKey(endpoint: "gh", header: "API_KEY")), "gh-key")
        let file = try String(contentsOf: folder.appendingPathComponent("runner.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("gh-key"), "no secret in runner.json")

        // Set again without that secret: its value goes.
        XCTAssertEqual(run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp"]), 0)
        XCTAssertNil(secrets.value(ProxyTokens.secretKey(endpoint: "gh", header: "API_KEY")))
        // A secret with no value given changes nothing.
        XCTAssertEqual(run(["endpoint", "set", "oss", "http://oss.example:7480/mcp", "--secret", "API_KEY"]), 2)
        XCTAssertEqual(RunnerConfig.read(folder)?.endpoints.map(\.name), ["gh"])
        XCTAssertEqual(run(["endpoint", "set", "x", "https://example.com/mcp"]), 2, "plain HTTP only")
    }

    func testAServerAddedIsGivenItsSettingsWithItsTokenAndNoSecret() throws {
        _ = run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--header", "CLIENT_ID=$SESSION_ID", "--secret", "API_KEY"],
                input: ["gh-key"])
        said = []
        XCTAssertEqual(run(["server", "add", "Builds", "--host", "mac.example.ts.net"]), 0)
        XCTAssertEqual(RunnerConfig.read(folder)?.servers, ["Builds"])
        let token = try XCTUnwrap(secrets.value(ProxyTokens.key(server: "Builds")))
        let body = try XCTUnwrap(said.last)
        XCTAssertFalse(body.contains("gh-key"), "the real key stays here")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let endpoint = try XCTUnwrap((settings["endpoints"] as? [[String: Any]])?.first)
        XCTAssertEqual(endpoint["url"] as? String, "http://mac.example.ts.net:7439/mcp/gh")
        let headers = try XCTUnwrap(endpoint["headers"] as? [[String: Any]])
        XCTAssertTrue(headers.contains { $0["name"] as? String == "CLIENT_ID" && $0["value"] as? String == "$SESSION_ID" })
        XCTAssertTrue(headers.contains { $0["name"] as? String == MCPProxy.tokenHeader && $0["value"] as? String == token && $0["secret"] as? Bool == true })

        // Added again: the same token. Removed: it no longer gets through.
        XCTAssertEqual(run(["server", "add", "Builds", "--host", "mac.example.ts.net"]), 0)
        XCTAssertEqual(secrets.value(ProxyTokens.key(server: "Builds")), token)
        XCTAssertEqual(run(["server", "remove", "Builds"]), 0)
        XCTAssertFalse(ProxyTokens.admits(token, servers: RunnerConfig.read(folder)?.servers ?? [], in: secrets))
    }

    func testTheAPNsKeyIsReadFromInputAndAServerGivenThePushProxy() throws {
        let p8 = ["-----BEGIN PRIVATE KEY-----", "MIGTAgEAMBMG", "-----END PRIVATE KEY-----", "after"]
        XCTAssertEqual(run(["apns", "set", "--key-id", "ABCDEFGHIJ", "--team-id", "TEAM123456"], input: p8), 0)
        XCTAssertEqual(secrets.value(APNsProxy.keySecret), "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG\n-----END PRIVATE KEY-----",
                       "read up to the key's last line")
        XCTAssertEqual(secrets.value(APNsProxy.keyIDSecret), "ABCDEFGHIJ")
        XCTAssertEqual(run(["apns", "set", "--key-id", "short", "--team-id", "TEAM123456"], input: p8), 2)
        XCTAssertEqual(run(["apns", "set", "--key-id", "ABCDEFGHIJ", "--team-id", "TEAM123456"], input: ["not a key"]), 2)

        XCTAssertEqual(run(["server", "push-proxy", "Builds", "--host", "192.168.131.1"]), 2, "a server added first")
        _ = run(["server", "add", "Builds", "--host", "192.168.131.1"])
        said = []
        XCTAssertEqual(run(["server", "push-proxy", "Builds", "--host", "192.168.131.1"]), 0)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(said.last).utf8)) as? [String: String])
        XCTAssertEqual(body["url"], "http://192.168.131.1:7439")
        XCTAssertEqual(body["token"], secrets.value(ProxyTokens.key(server: "Builds")))

        said = []
        _ = run(["status"])
        XCTAssertTrue(said.joined().contains("Pushes: signed with APNs key ABCDEFGHIJ (team TEAM123456)"), said.joined())
        XCTAssertFalse(said.joined().contains("MIGT"))
        XCTAssertEqual(run(["apns", "remove"]), 0)
        XCTAssertNil(secrets.value(APNsProxy.keySecret))
    }

    func testStatusSaysWhatIsKeptButNoSecret() {
        _ = run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--secret", "API_KEY"], input: ["gh-key"])
        _ = run(["server", "add", "Builds", "--host", "h"])
        said = []
        XCTAssertEqual(run(["status"]), 0)
        let text = said.joined(separator: "\n")
        XCTAssertTrue(text.contains("gh: http://127.0.0.1:7470/mcp; secret: API_KEY (kept)"), text)
        XCTAssertTrue(text.contains("Visor servers: Builds"), text)
        XCTAssertFalse(text.contains("gh-key"))
        XCTAssertEqual(run(["nonsense"]), 2)
    }
}
