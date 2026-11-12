// visor-runner-agent's commands (docs/co-tenancy.md): MCP servers set with
// their secret headers read from standard input and kept by the Runner
// alone; a Visor server added is given its settings, every MCP server at
// the proxy with its own token, and no secret.

import _CryptoExtras
import Foundation
import VisorRunner
import Testing

@Suite final class RunnerCommandTests {
    private var folder: URL!
    private var secrets: MemorySecrets!
    private var said: [String] = []

    init() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-command-\(UUID().uuidString)", isDirectory: true)
        secrets = MemorySecrets()
        said = []
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String], input: [String] = []) -> Int32 {
        var lines = input[...]
        return RunnerCommand(folder: folder, secrets: secrets, input: { lines.popFirst() }, output: { self.said.append($0) }).run(arguments)
    }

    @Test func testAnEndpointsSecretsAreReadFromInputAndKeptHereAlone() throws {
        #expect(run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--header", "CLIENT_ID=$SESSION_ID", "--secret", "API_KEY"],
                           input: ["gh-key\n"]) == 0)
        let config = try #require(RunnerConfig.read(folder))
        #expect(config.endpoints == ([.init(name: "gh", url: "http://127.0.0.1:7470/mcp", headers: ["CLIENT_ID": "$SESSION_ID"],
                                                secretHeaders: ["API_KEY"])]))
        #expect((secrets.value(ProxyTokens.secretKey(endpoint: "gh", header: "API_KEY"))) == "gh-key")
        let file = try String(contentsOf: folder.appendingPathComponent("runner.json"), encoding: .utf8)
        #expect(!file.contains("gh-key"), "no secret in runner.json")

        // Set again without that secret: its value goes.
        #expect(run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp"]) == 0)
        #expect((secrets.value(ProxyTokens.secretKey(endpoint: "gh", header: "API_KEY"))) == nil)
        // A secret with no value given changes nothing.
        #expect(run(["endpoint", "set", "shireworks", "http://shireworks.example:7480/mcp", "--secret", "API_KEY"]) == 2)
        #expect((RunnerConfig.read(folder)?.endpoints.map(\.name)) == ["gh"])
        #expect(run(["endpoint", "set", "x", "https://example.com/mcp"]) == 2, "plain HTTP only")
    }

    @Test func testAServerAddedIsGivenItsSettingsWithItsTokenAndNoSecret() throws {
        _ = run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--header", "CLIENT_ID=$SESSION_ID", "--secret", "API_KEY"],
                input: ["gh-key"])
        said = []
        #expect(run(["server", "add", "Builds", "--host", "mac.example.ts.net"]) == 0)
        #expect((RunnerConfig.read(folder)?.servers) == ["Builds"])
        let token = try #require(secrets.value(ProxyTokens.key(server: "Builds")))
        let body = try #require(said.last)
        #expect(!body.contains("gh-key"), "the real key stays here")
        let settings = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let endpoint = try #require((settings["endpoints"] as? [[String: Any]])?.first)
        #expect((endpoint["url"] as? String) == "http://mac.example.ts.net:7439/mcp/gh")
        let headers = try #require(endpoint["headers"] as? [[String: Any]])
        #expect(headers.contains { $0["name"] as? String == "CLIENT_ID" && $0["value"] as? String == "$SESSION_ID" })
        #expect(headers.contains { $0["name"] as? String == MCPProxy.tokenHeader && $0["value"] as? String == token && $0["secret"] as? Bool == true })

        // Added again: the same token. Removed: it no longer gets through.
        #expect(run(["server", "add", "Builds", "--host", "mac.example.ts.net"]) == 0)
        #expect((secrets.value(ProxyTokens.key(server: "Builds"))) == token)
        #expect(run(["server", "remove", "Builds"]) == 0)
        #expect(!(ProxyTokens.admits(token, servers: RunnerConfig.read(folder)?.servers ?? [], in: secrets)))
    }

    @Test func testTheAPNsKeyIsReadFromInputAndAServerGivenThePushProxy() throws {
        let p8 = ["-----BEGIN PRIVATE KEY-----", "MIGTAgEAMBMG", "-----END PRIVATE KEY-----", "after"]
        #expect(run(["apns", "set", "--key-id", "ABCDEFGHIJ", "--team-id", "TEAM123456"], input: p8) == 0)
        #expect(secrets.value(APNsProxy.keySecret) == "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG\n-----END PRIVATE KEY-----", "read up to the key's last line")
        #expect(secrets.value(APNsProxy.keyIDSecret) == "ABCDEFGHIJ")
        #expect(run(["apns", "set", "--key-id", "short", "--team-id", "TEAM123456"], input: p8) == 2)
        #expect(run(["apns", "set", "--key-id", "ABCDEFGHIJ", "--team-id", "TEAM123456"], input: ["not a key"]) == 2)

        #expect(run(["server", "push-proxy", "Builds", "--host", "192.168.131.1"]) == 2, "a server added first")
        _ = run(["server", "add", "Builds", "--host", "192.168.131.1"])
        said = []
        #expect(run(["server", "push-proxy", "Builds", "--host", "192.168.131.1"]) == 0)
        let last = try #require(said.last)
        let body = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String])
        #expect((body["url"]) == "http://192.168.131.1:7439")
        #expect((body["token"]) == (secrets.value(ProxyTokens.key(server: "Builds"))))

        said = []
        _ = run(["status"])
        #expect(said.joined().contains("Pushes: signed with APNs key ABCDEFGHIJ (team TEAM123456)"), Comment(rawValue: said.joined()))
        #expect(!(said.joined().contains("MIGT")))
        #expect(run(["apns", "remove"]) == 0)
        #expect(secrets.value(APNsProxy.keySecret) == nil)
    }

    @Test func testAFrontIsSetForAServersClients() throws {
        #expect(run(["front", "set", "co-tenant", "--port", "7440", "--to", "192.168.131.3:7433"]) == 0)
        #expect((RunnerConfig.read(folder)?.fronts) == [.init(name: "co-tenant", port: 7440, host: "192.168.131.3", hostPort: 7433)])
        #expect(run(["front", "set", "co-tenant", "--port", "7441", "--to", "[fd00::3]:7433"]) == 0, "set again: replaced")
        #expect((RunnerConfig.read(folder)?.fronts) == [.init(name: "co-tenant", port: 7441, host: "fd00::3", hostPort: 7433)])
        #expect(run(["front", "set", "builds", "--port", "7441", "--to", "192.168.131.4:7433"]) == 2, "a port is one server's")
        #expect(run(["front", "set", "builds", "--port", "70000", "--to", "192.168.131.4:7433"]) == 2)
        #expect(run(["front", "set", "builds", "--port", "7442", "--to", "192.168.131.4"]) == 2, "the server's port is needed")
        said = []
        _ = run(["status"])
        #expect(said.joined().contains("Front for co-tenant: port 7441 to fd00::3:7433"), Comment(rawValue: said.joined()))
        #expect(run(["front", "remove", "co-tenant"]) == 0)
        #expect((RunnerConfig.read(folder)?.fronts) == [])
        #expect(run(["front", "remove", "co-tenant"]) == 2)
    }

    @Test func testTheGitHubProxyIsSetUpForAServer() throws {
        #expect(run(["server", "add", "co-tenant", "--host", "192.168.131.1"]) == 0)
        #expect(run(["github-proxy", "server", "co-tenant", "--host", "192.168.131.1", "--sessions", "S"]) == 2, "no proxy port yet")
        #expect(run(["github-proxy", "port", "7441"]) == 0)
        said = []
        #expect(run(["github-proxy", "server", "co-tenant", "--host", "192.168.131.1", "--sessions", "S, T"]) == 0)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(said.joined().utf8)) as? [String: Any])
        #expect((body["url"] as? String) == "http://192.168.131.1:7441")
        #expect((body["token"] as? String) == ProxyTokens.token(for: "co-tenant", in: secrets))
        #expect((body["sessions"] as? [String]) == ["S", "T"])
        #expect((body["authority"] as? String)?.hasPrefix("-----BEGIN CERTIFICATE-----") == true)
        #expect(run(["github-proxy", "server", "nobody", "--host", "192.168.131.1", "--sessions", "*"]) == 2)
    }

    @Test func testTheGitHubProxysAppIsSetItsKeyKeptHereOnly() throws {
        let pem = try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
        let lines = pem.split(separator: "\n").map(String.init)
        #expect(run(["github-proxy", "app", "--app-id", "123", "--installation", "456"], input: ["not a key"]) == 2)
        #expect(run(["github-proxy", "app", "--app-id", "x", "--installation", "456"], input: lines) == 2, "ids are numbers")
        said = []
        #expect(run(["github-proxy", "app", "--app-id", "123", "--installation", "456"], input: lines) == 0)
        #expect((RunnerConfig.read(folder)?.githubAppID) == "123")
        #expect((RunnerConfig.read(folder)?.githubInstallation) == "456")
        #expect(secrets.value(RunnerCommand.githubAppKeySecret) == (pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"))
        #expect(!(said.joined().contains("PRIVATE KEY")), "never said back")
        #expect(!((try String(contentsOf: folder.appendingPathComponent("runner.json"), encoding: .utf8)).contains("PRIVATE KEY")))
    }

    @Test func testAFrontCanSayHowItsServerStartsAgain() throws {
        let start = "/usr/local/bin/container exec -d visor-co-tenant visor-server start"
        #expect(run(["front", "set", "co-tenant", "--port", "7440", "--to", "192.168.131.3:7433", "--start", start]) == 0)
        #expect((RunnerConfig.read(folder)?.fronts) == [.init(name: "co-tenant", port: 7440, host: "192.168.131.3", hostPort: 7433, start: start)])
        said = []
        _ = run(["status"])
        #expect(said.joined().contains("started again with: " + start), Comment(rawValue: said.joined()))
        #expect(run(["front", "set", "co-tenant", "--port", "7440", "--to", "192.168.131.3:7433", "--start", " "]) == 2, "a command, not nothing")
        // A runner.json from before has no command: none is run.
        let before = #"{"fronts":[{"name":"co-tenant","port":7440,"host":"192.168.131.3","hostPort":7433}]}"#
        try Data(before.utf8).write(to: folder.appendingPathComponent("runner.json"))
        #expect((RunnerConfig.read(folder)?.fronts.first?.start) == nil)
    }

    @Test func testStatusSaysWhatIsKeptButNoSecret() {
        _ = run(["endpoint", "set", "gh", "http://127.0.0.1:7470/mcp", "--secret", "API_KEY"], input: ["gh-key"])
        _ = run(["server", "add", "Builds", "--host", "h"])
        said = []
        #expect(run(["status"]) == 0)
        let text = said.joined(separator: "\n")
        #expect(text.contains("gh: http://127.0.0.1:7470/mcp; secret: API_KEY (kept)"), Comment(rawValue: text))
        #expect(text.contains("Visor servers: Builds"), Comment(rawValue: text))
        #expect(!text.contains("gh-key"))
        #expect(run(["nonsense"]) == 2)
    }
}
