// agent-proxy's host in Visor (VisorAgentProxyHost): ServerSettings'
// `agentProxy` read field by field and kept as the last good, its secrets
// the server's `agent-proxy/` items alone, the stdin import, the launchd
// job's decisions, and the MCP pass-through started from the settings with
// the server's secrets, end to end.

import CAgentProxyPOSIX
import Foundation
import Testing
@testable import VisorAgentProxy
@testable import VisorAgentProxyHost
import VisorLaunchAgent
import VisorServer

@Suite struct AgentProxyHostTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-proxy-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func settingsAreOffByDefaultAndReadFieldByField() throws {
        #expect(ServerSettings().agentProxy == nil, "nothing runs unless it's configured")
        let json = #"{"lan":true,"agentProxy":{"mcp":{"upstreams":[{"name":"gh","url":"http://127.0.0.1:7470/mcp","secretHeaders":["API_KEY"]}]}}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        let proxy = try #require(settings.agentProxy)
        #expect(proxy.mcp?.port == 7439, "MultiPass's and Shireworks' port unless said")
        #expect(proxy.mcp?.upstreams == [AgentProxySettings.Upstream(name: "gh", url: "http://127.0.0.1:7470/mcp", secretHeaders: ["API_KEY"])])
        #expect(proxy.relayPort == nil && proxy.egressAllow.isEmpty && proxy.dialIns.isEmpty)
        // Kept as it was read, so the server's own saves never drop it.
        let again = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.agentProxy == proxy)
        // One that isn't one leaves the rest of the settings as they are.
        let broken = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"lan":true,"agentProxy":{"mcp":7}}"#.utf8))
        #expect(broken.lan && broken.agentProxy == nil)
        #expect(!String(decoding: try JSONEncoder().encode(ServerSettings()), as: UTF8.self).contains("agentProxy"))
    }

    @Test func theLastGoodStandsInForSettingsThatCantBeRead() throws {
        let places = AgentProxyHost.Places(dataDirectory: try folder())
        #expect(AgentProxyHost.loadKeeping(places) == nil, "no settings.json: nothing to do")
        #expect(AgentProxyHost.isConfigured(places) == false)
        try Data(#"{"agentProxy":{"relayPort":7438}}"#.utf8).write(to: places.settingsFile)
        let loaded = try #require(AgentProxyHost.loadKeeping(places))
        #expect(loaded.settings.relayPort == 7438 && !loaded.kept)
        let mode = try FileManager.default.attributesOfItem(atPath: places.keptFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data(#"{"agentProxy":"#.utf8).write(to: places.settingsFile)
        let kept = try #require(AgentProxyHost.loadKeeping(places))
        #expect(kept.settings.relayPort == 7438 && kept.kept, "the last good, while settings.json is broken")
        #expect(AgentProxyHost.isConfigured(places) == nil, "not known: nothing is stopped on it")
        try Data(#"{"lan":true}"#.utf8).write(to: places.settingsFile)
        #expect(AgentProxyHost.loadKeeping(places) == nil, "taken out: nothing to do")
        #expect(AgentProxyHost.isConfigured(places) == false)
    }

    @Test func itsSecretsAreTheServersAgentProxyItemsAlone() throws {
        let secrets = MemorySecrets()
        secrets.set("password", "the server's")
        let store = ProxySecretStore(secrets: secrets)
        #expect(throws: (any Error).self) { try store.item("password") }
        #expect(throws: (any Error).self) { try store.setItem("password", Data("x".utf8)) }
        #expect(try store.item("agent-proxy/ca.pem") == nil)
        try store.setItem("agent-proxy/ca.pem", Data("pem".utf8))
        #expect(secrets.get("agent-proxy/ca.pem") == "pem")
        #expect(secrets.get("password") == "the server's")
        let ca = try AgentProxyCA.kept(in: store)
        let pem = try ca.pem
        #expect(secrets.get(AgentProxyCA.keyAccount) != nil && secrets.get(AgentProxyCA.certificateAccount) == pem)
    }

    @Test func aKeptSecretIsReadAgainAndComparedWhole() throws {
        let secrets = MemorySecrets()
        let token = KeptSecret("mcp/token", in: secrets, every: 0)
        #expect(!token.isSet && !token.admits(""), "none admits nothing, not even nothing")
        secrets.set("agent-proxy/mcp/token", "one-token\n")
        #expect(token.value == "one-token")
        #expect(token.admits("one-token") && !token.admits("one-toke") && !token.admits("one-tokens"))
        let slow = KeptSecret("mcp/token", in: secrets, every: 3600)
        #expect(slow.value == "one-token")
        secrets.set("agent-proxy/mcp/token", "two")
        #expect(slow.value == "one-token", "read at most once in its interval")
    }

    @Test func theImportNamesAreAgentProxysOwn() {
        #expect(AgentProxySettings.importableName("mcp/token") == "mcp/token")
        #expect(AgentProxySettings.importableName("agent-proxy/mcp/token") == "mcp/token", "as Shireworks named it")
        #expect(AgentProxySettings.importableName("github-token") == "github-token")
        #expect(AgentProxySettings.importableName("mcp/gh/API_KEY") == "mcp/gh/api_key")
        for refused in ["password", "relay-token", "ca-key.pem", "mcp/gh", "mcp//x", "mcp/gh/a b", "mcp/a/b/c", "agent-proxy/ca.pem", ""] {
            #expect(AgentProxySettings.importableName(refused) == nil, "\(refused)")
        }
    }

    @Test func secretSetTakesStandardInputAndNeverATerminal() throws {
        let secrets = MemorySecrets()
        func piped(_ text: String) throws -> FileHandle {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            return pipe.fileHandleForReading
        }
        let said = try AgentProxyCommand.run(["secret-set", "agent-proxy/mcp/token"], secrets: secrets, input: try piped("tok-1\n"),
                                             inputIsTerminal: false)
        #expect(said.contains("agent-proxy/mcp/token kept"))
        #expect(!said.contains("tok-1"), "the value never said back")
        #expect(secrets.get("agent-proxy/mcp/token") == "tok-1")
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-token"], secrets: secrets, input: try piped("x"), inputIsTerminal: true)
        }
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-token"], secrets: secrets, input: try piped(""), inputIsTerminal: false)
        }
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-token"], secrets: secrets, input: try piped("a\nb\n"), inputIsTerminal: false)
        }
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "password"], secrets: secrets, input: try piped("x"), inputIsTerminal: false)
        }
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-token", "value"], secrets: secrets, input: try piped(""), inputIsTerminal: false)
        }
        #expect(secrets.get("agent-proxy/github-token") == nil)
        _ = try AgentProxyCommand.run(["secret-remove", "mcp/token"], secrets: secrets, input: try piped(""), inputIsTerminal: true)
        #expect(secrets.get("agent-proxy/mcp/token") == nil)
    }

    @Test func theJobRunsOnlyFromAnAppInApplications() {
        #expect(AgentProxyJob.installProblem("/Applications/Visor.app/Contents/MacOS/Visor") == nil)
        #expect(AgentProxyJob.installProblem("/Applications/Visor Alpha.app/Contents/MacOS/Visor") == nil)
        for refused in ["/Users/me/bazel-bin/Visor.app/Contents/MacOS/Visor", "/Applications/Visor.app/Contents/Helpers/visor-agent-host",
                        "/Applications/Other/Visor.app/Contents/MacOS/Visor", "/Applications/Visor"] {
            #expect(AgentProxyJob.installProblem(refused) != nil, "\(refused)")
        }
        #expect(AgentProxyJob.label(bundleID: "com.LoganShire.Visor") == "com.LoganShire.Visor.agent-proxy")
    }

    @Test func theJobIsSettledAsTheSettingsAndTheAppSay() throws {
        let app = "/Applications/Visor.app/Contents/MacOS/Visor"
        let plist = AgentProxyJob.Plist(program: [app, "--agent-proxy"], version: "0.62.1", settings: "abc")
        func state(_ configured: Bool?, plist: AgentProxyJob.Plist?, running: Bool?, executable: String = app, version: String = "0.62.1",
                   settings: String = "abc") -> AgentProxyJob.State {
            AgentProxyJob.State(configured: configured, executable: executable, version: version, settings: settings, plist: plist, running: running)
        }
        #expect(AgentProxyJob.decide(state(false, plist: nil, running: false)) == .nothing)
        #expect(AgentProxyJob.decide(state(nil, plist: nil, running: false)) == .nothing)
        #expect(AgentProxyJob.decide(state(false, plist: plist, running: true)) == .stop)
        #expect(AgentProxyJob.decide(state(true, plist: nil, running: false)) == .start)
        #expect(AgentProxyJob.decide(state(true, plist: plist, running: true)) == .leave, "a restart of the server cuts nothing")
        #expect(AgentProxyJob.decide(state(true, plist: plist, running: true, version: "0.62.2")) != .leave)
        #expect(AgentProxyJob.decide(state(true, plist: plist, running: true, settings: "def")) == .restart("agentProxy changed"))
        #expect(AgentProxyJob.decide(state(true, plist: nil, running: true)) == .restart("running without its plist"))
        #expect(AgentProxyJob.decide(state(nil, plist: plist, running: true)) == .hold("settings.json can't be read"))
        #expect(AgentProxyJob.decide(state(true, plist: plist, running: nil)) == .hold("launchd didn't say whether it runs"))
        if case .refuse = AgentProxyJob.decide(state(true, plist: nil, running: false, executable: "/tmp/Visor.app/Contents/MacOS/Visor")) {} else {
            Issue.record("a copy elsewhere never writes the job")
        }
        let job = AgentProxyJob.job(label: "com.LoganShire.Visor.agent-proxy", executable: app, version: "0.62.1", settings: "abc",
                                    log: "/tmp/agent-proxy.log")
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        #expect(AgentProxyJob.plist(from: data) == plist, "what it writes is what it reads back")
        #expect((job["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "started again after a failure alone")
        #expect(AgentProxyHost.digest(AgentProxySettings(relayPort: 1)) != AgentProxyHost.digest(AgentProxySettings(relayPort: 2)))
        #expect(AgentProxyHost.digest(AgentProxySettings(relayPort: 1)) == AgentProxyHost.digest(AgentProxySettings(relayPort: 1)))
    }

    /// The pass-through as the settings and the server's secrets make it:
    /// the sessions' token from `agent-proxy/mcp/token`, an upstream's
    /// secret header from `agent-proxy/mcp/<name>/<header>`.
    @Test func thePassThroughIsMadeFromTheSettingsAndTheServersSecrets() throws {
        let upstream = try #require(FakeEndpoint())
        defer { upstream.stop() }
        let secrets = MemorySecrets()
        secrets.set("agent-proxy/mcp/token", "sessions-token")
        secrets.set("agent-proxy/mcp/gh/api_key", "gh-secret")
        let places = AgentProxyHost.Places(dataDirectory: try folder())
        var running: AgentProxyHost.Running?
        var port = 0
        for _ in 0..<20 where running == nil {
            port = Int.random(in: 20000...45000)
            let settings = AgentProxySettings(mcp: .init(port: port, upstreams: [.init(name: "gh", url: "http://127.0.0.1:\(upstream.port)/mcp",
                                                                                     headers: ["X-Plain": "yes"], secretHeaders: ["API_KEY"])]))
            running = AgentProxyHost.start(settings, places: places, secrets: secrets, version: "test", log: { _ in })
            if running?.complete == false { running = nil }
        }
        let proxy = try #require(running)
        defer { proxy.stop() }
        #expect(proxy.relay == nil, "no relay listener without relayPort")
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        func ask(_ token: String) -> String {
            let connection = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
            guard connection >= 0 else { return "" }
            defer { close(connection) }
            let request = "POST /mcp/gh HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                + "X-Visor-Proxy: \(token)\r\n\r\n" + body
            _ = Array(request.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                answer.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: answer, as: UTF8.self)
        }
        #expect(ask("wrong").hasPrefix("HTTP/1.1 401"), "another token is refused")
        #expect(upstream.requests.withLock { $0.isEmpty })
        #expect(ask("sessions-token").hasPrefix("HTTP/1.1 200"))
        let heard = try #require(upstream.requests.withLock { $0.first })
        #expect(heard.lowercased().contains("api_key: gh-secret"), "\(heard)")
        #expect(heard.contains("X-Plain: yes"), "\(heard)")
        #expect(!heard.contains("sessions-token"), "the sessions' token stays here")
    }
}
