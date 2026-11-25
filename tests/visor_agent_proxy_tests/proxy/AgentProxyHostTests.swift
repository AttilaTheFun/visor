// agent-proxy's host in Visor (VisorAgentProxyHost): ServerSettings'
// `agentProxy` read field by field and kept as the last good, its secrets
// the server's `agent-proxy/` items alone, the stdin import, the launchd
// job's decisions, and the MCP pass-through started from the settings with
// the server's secrets, end to end; and its own dial-in, by which a
// container's agent reaches it through the relay with its own token.

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
        #expect(AgentProxySettings.importableName("claude/oauth-token") == "claude/oauth-token")
        for app in ["github-app/key", "github-app/id", "github-app/installation"] {
            #expect(AgentProxySettings.importableName(app) == app)
            #expect(AgentProxySettings.importableName("agent-proxy/" + app) == app)
        }
        #expect(AgentProxySettings.importableName("mcp/gh/API_KEY") == "mcp/gh/api_key")
        for refused in ["password", "relay-token", "ca-key.pem", "mcp/gh", "mcp//x", "mcp/gh/a b", "mcp/a/b/c", "agent-proxy/ca.pem", "claude/other", "",
                        "github-app/secret", "github-app"] {
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
        // The App's key is a PEM, every line of it kept (a stand-in's, not a key).
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\nBBBB\n-----END RSA PRIVATE KEY-----"
        let kept = try AgentProxyCommand.run(["secret-set", "github-app/key"], secrets: secrets, input: try piped(pem + "\n"), inputIsTerminal: false)
        #expect(kept.contains("agent-proxy/github-app/key kept") && !kept.contains("AAAA"))
        #expect(secrets.get("agent-proxy/github-app/key") == pem)
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-app/key"], secrets: secrets, input: try piped("ghp_x\n"), inputIsTerminal: false)
        }
        #expect(secrets.get("agent-proxy/github-app/key") == pem, "what isn't a PEM isn't kept")
        _ = try AgentProxyCommand.run(["secret-set", "github-app/id"], secrets: secrets, input: try piped("123456\n"), inputIsTerminal: false)
        #expect(secrets.get("agent-proxy/github-app/id") == "123456")
        #expect(throws: AgentProxyCommand.Failure.self) {
            try AgentProxyCommand.run(["secret-set", "github-app/id"], secrets: secrets, input: try piped("1\n2\n"), inputIsTerminal: false)
        }
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

    /// The pass-through's own dial-in (0.72.1): `mcp.agent.internal:80`, made by agent-proxy wherever it runs the
    /// pass-through, to the pass-through's port alone; one of the settings' by that name is passed over. What a
    /// container's Claude is told is that dial-in's address.
    @Test func thePassThroughHasADialInOfItsOwn() {
        #expect(AgentProxyHost.passThroughDialIn(AgentProxySettings(relayPort: 7438)) == nil, "no pass-through, no dial-in to it")
        #expect(AgentProxyHost.passThroughDialIn(AgentProxySettings(mcp: .init())) == DialIn(name: "mcp", port: 80, hostPort: 7439))
        #expect(AgentProxyHost.passThroughDialIn(AgentProxySettings(mcp: .init(port: 7500))) == DialIn(name: "mcp", port: 80, hostPort: 7500))
        #expect(AgentProxyHost.passThroughDialIn(AgentProxySettings(gh: .init())) == DialIn(name: "mcp", port: 80, hostPort: 7439),
                "gh_mcp alone: the pass-through on its own port")
        #expect(AgentProxyHost.passThroughDialIn(AgentProxySettings(mcp: .init(port: 70000))) == nil, "a port that isn't one")
        let lines = Lines()
        let settings = AgentProxySettings(dialIns: [.init(name: "mcp", port: 80, hostPort: 7433), .init(name: "visor", port: 7434)])
        #expect(AgentProxyHost.dialIns(settings, log: { lines.add($0) }) == [DialIn(name: "visor", port: 7434, hostPort: 7434)])
        #expect(lines.all.contains { $0.contains("the MCP pass-through's own") }, "\(lines.all)")
        #expect(DialIn.passThrough(to: 7439).host == AgentProxySettings.passThroughHost)
        #expect(AgentProxySettings.containerURL(of: "gh") == "http://mcp.agent.internal/mcp/gh")
    }

    /// What the pass-through serves, as a container's Claude is told of it: each upstream, then gh_mcp's where it's
    /// in-process, each once; none without a pass-through.
    @Test func theContainersServersAreWhatThePassThroughServes() {
        #expect(AgentProxySettings(relayPort: 7438).passThroughServers.isEmpty)
        let upstreams: [AgentProxySettings.Upstream] = [.init(name: "oss", url: "http://127.0.0.1:7481/mcp"),
                                                         .init(name: "nimbus", url: "http://127.0.0.1:7490/mcp"),
                                                         .init(name: "../x", url: "http://127.0.0.1:1/mcp")]
        #expect(AgentProxySettings(mcp: .init(upstreams: upstreams), gh: .init()).passThroughServers == ["oss", "nimbus", "gh"])
        #expect(AgentProxySettings(mcp: .init(upstreams: [.init(name: "gh", url: "http://127.0.0.1:7470/mcp")]), gh: .init()).passThroughServers
                == ["gh"], "an upstream named gh wins, once")
        #expect(AgentProxySettings(gh: .init()).passThroughServers == ["gh"])
        #expect(VisorServer.containerMCPServers(AgentProxySettings(mcp: .init(upstreams: upstreams)))
                == ["oss": "http://mcp.agent.internal/mcp/oss", "nimbus": "http://mcp.agent.internal/mcp/nimbus"])
        #expect(VisorServer.containerMCPServers(nil).isEmpty)
    }

    /// A container reaches the pass-through through the relay by its dial-in, `mcp.agent.internal:80`, and nothing else
    /// on loopback by that name; its call to Nimbus's is let in with its agent's own token (the server's to say whose),
    /// and goes on as that token's session with Nimbus's secret header from Visor's secrets, which the container never
    /// sees; with no token, or one the server says is no one's, it's refused (401), and to any other server (403).
    @Test func aContainerReachesThePassThroughByItsDialInWithItsAgentsToken() throws {
        let upstream = try #require(FakeEndpoint())
        defer { upstream.stop() }
        let secrets = MemorySecrets()
        secrets.set("agent-proxy/mcp/token", "sessions-token")
        secrets.set("agent-proxy/relay-token", "relay-secret")
        secrets.set("agent-proxy/mcp/nimbus/api_key", "nimbus-secret")
        let places = AgentProxyHost.Places(dataDirectory: try folder())
        var running: AgentProxyHost.Running?
        var mcpPort = 0
        var relayPort = 0
        for _ in 0..<20 where running == nil {
            mcpPort = Int.random(in: 20000...32000)
            relayPort = Int.random(in: 33000...45000)
            let upstreams: [AgentProxySettings.Upstream] = ["nimbus", "gh", "oss", "shireworks"].map { name in
                .init(name: name, url: "http://127.0.0.1:\(upstream.port)/mcp", headers: ["CLIENT_ID": "$SESSION_ID"], secretHeaders: ["API_KEY"])
            }
            let settings = AgentProxySettings(mcp: .init(port: mcpPort, upstreams: upstreams), relayPort: relayPort)
            running = AgentProxyHost.start(settings, places: places, secrets: secrets, version: "test",
                                           agentSession: { $0 == "agent.own.token" ? "s-container" : nil }, log: { _ in })
            if running?.complete == false {
                running?.stop()
                running = nil
            }
        }
        let proxy = try #require(running)
        defer { proxy.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        func call(_ token: String?, _ server: String = "nimbus") -> String {
            "POST /mcp/\(server) HTTP/1.1\r\nHost: mcp.agent.internal\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                + (token.map { "X-Visor-Proxy: \($0)\r\n" } ?? "") + "CLIENT_ID: s-other\r\n\r\n" + body
        }
        let answered = relayed(relayPort, connect: "mcp.agent.internal:80", then: call("agent.own.token"))
        #expect(answered.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\nHTTP/1.1 200"), "\(answered)")
        let heard = try #require(upstream.requests.withLock { $0.first })
        #expect(heard.contains("CLIENT_ID: s-container\r\n") && !heard.contains("s-other"), "as its token's session: \(heard)")
        #expect(!heard.contains("agent.own.token"), "the token stops at the pass-through")
        #expect(heard.lowercased().contains("api_key: nimbus-secret"), "Nimbus's header added here, from Visor's secrets: \(heard)")
        for server in ["gh", "oss", "shireworks"] {
            let refused = relayed(relayPort, connect: "mcp.agent.internal:80", then: call("agent.own.token", server))
            #expect(refused.contains("HTTP/1.1 403"), "\(server): \(refused)")
        }
        for token in [nil, "someone.elses.token", "sessions-token-guess"] {
            let refused = relayed(relayPort, connect: "mcp.agent.internal:80", then: call(token))
            #expect(refused.contains("HTTP/1.1 401"), "\(token ?? "none"): \(refused)")
        }
        // The dial-in's own name and port alone: no other port of it, and not the pass-through's port by loopback.
        for connect in ["mcp.agent.internal:\(mcpPort)", "mcp.agent.internal:7434", "127.0.0.1:\(mcpPort)"] {
            #expect(relayed(relayPort, connect: connect, then: call("agent.own.token")).hasPrefix("HTTP/1.1 403"), "\(connect)")
        }
        #expect(upstream.requests.withLock { $0.count } == 1, "nothing refused reached the upstream")
    }

    /// `request` sent through the relay at `port`, as the container's (the relay's header with its token), once
    /// `CONNECT <connect>` is answered 200; everything heard back, to the stream's end.
    private func relayed(_ port: Int, connect: String, then request: String) -> String {
        let socket = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        guard socket >= 0 else { return "" }
        defer { close(socket) }
        let first = ProxyProtocolHeader.relayed(lease: "visor-sessions", relayToken: "relay-secret").encoded()
            + Array("CONNECT \(connect) HTTP/1.1\r\nHost: \(connect)\r\n\r\n".utf8)
        _ = first.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        var heard: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        var sent = false
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            heard += buffer[0..<count]
            let text = String(decoding: heard, as: UTF8.self)
            if !sent, text.contains("\r\n\r\n") {
                sent = true
                if text.hasPrefix("HTTP/1.1 200") { _ = Array(request.utf8).withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } }
            }
        }
        return String(decoding: heard, as: UTF8.self)
    }
}
