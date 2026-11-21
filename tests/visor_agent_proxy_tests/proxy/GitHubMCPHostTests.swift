// gh_mcp in agent-proxy (0.66): a name with no upstream answered by a server
// of agent-proxy's own (InProcessMCP), the sessions' token checked first and
// stopping there; an upstream of the name winning, so the cut-over is a
// settings change; and `agentProxy.gh` made into gh_mcp at the
// pass-through's `/mcp/gh` end to end: its tools listed, each session as
// its own app (read again from settings.json at each call), its calls in
// the audit log, in the server's logs folder unless said.

import CAgentProxyPOSIX
import Foundation
import Synchronization
import Testing
@testable import VisorAgentProxy
@testable import VisorAgentProxyHost
import VisorGHMCP
import VisorServer

/// An in-process server played by the test: what it was asked, kept.
private final class FakeInProcess: InProcessMCP {
    let heard = Mutex<[[String: String]]>([])

    func answer(method: String, headers: [String: String], body: Data) async -> InProcessMCPAnswer {
        heard.withLock { $0.append(headers) }
        try? await Task.sleep(for: .milliseconds(20))
        return InProcessMCPAnswer(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"in":"process"}"#.utf8))
    }
}

@Suite struct GitHubMCPHostTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gh-mcp-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A POST to the pass-through, and its status and body.
    private func ask(_ port: UInt16, _ path: String, token: String?, body: String, extra: [String] = []) -> (status: String, body: String) {
        let connection = agent_proxy_connect_tcp("127.0.0.1", port)
        guard connection >= 0 else { return ("", "") }
        defer { close(connection) }
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { head += "X-Visor-Proxy: \(token)\r\n" }
        for line in extra { head += line + "\r\n" }
        _ = Array((head + "\r\n" + body).utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: answer, as: UTF8.self)
        return (text.split(separator: " ").dropFirst().first.map(String.init) ?? "",
                text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? "")
    }

    /// A pass-through on a free port.
    private func proxy(_ endpoints: [NativeMCPProxy.Endpoint], inProcess: [String: any InProcessMCP]) throws -> NativeMCPProxy {
        for _ in 0..<20 {
            if let proxy = NativeMCPProxy(port: UInt16.random(in: 20000...45000), endpoints: { endpoints }, admits: { $0 == "one-token" },
                                          secret: { _, _ in nil }, inProcess: inProcess) {
                proxy.start()
                return proxy
            }
        }
        throw ProxyUnavailable()
    }

    private struct ProxyUnavailable: Error {}

    @Test func aNameWithNoUpstreamIsAnsweredInProcess() throws {
        let served = FakeInProcess()
        let proxy = try proxy([], inProcess: ["gh": served])
        defer { proxy.stop() }
        let answered = ask(proxy.port, "/mcp/gh", token: "one-token", body: "{}", extra: ["CLIENT_ID: s1"])
        #expect(answered.status == "200" && answered.body == #"{"in":"process"}"#)
        let headers = try #require(served.heard.withLock { $0.first })
        #expect(headers["CLIENT_ID"] == "s1", "the session's own headers reach it")
        #expect(!headers.keys.contains { $0.lowercased() == "x-visor-proxy" }, "the sessions' token stops at the proxy")
        #expect(ask(proxy.port, "/mcp/gh", token: nil, body: "{}").status == "401")
        #expect(ask(proxy.port, "/mcp/gh", token: "two-token", body: "{}").status == "401")
        #expect(ask(proxy.port, "/mcp/other", token: "one-token", body: "{}").status == "404")
        #expect(served.heard.withLock { $0.count } == 1, "nothing without the token reached it")
    }

    @Test func anUpstreamOfTheNameWins() throws {
        let upstream = try #require(FakeEndpoint())
        defer { upstream.stop() }
        let served = FakeInProcess()
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "gh", url: "http://127.0.0.1:\(upstream.port)/mcp")], inProcess: ["gh": served])
        defer { proxy.stop() }
        let answered = ask(proxy.port, "/mcp/gh", token: "one-token", body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(answered.body == #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        #expect(upstream.requests.withLock { $0.count } == 1)
        #expect(served.heard.withLock { $0.isEmpty }, "passed through while the upstream is configured")
    }

    @Test func ghSettingsReadFieldByField() throws {
        let json = #"{"agentProxy":{"gh":{"agent":"logan-shire-codex","sessionAgents":{"s1":"claude"},"auditLog":"/tmp/x.log"}}}"#
        let gh = try #require(try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8)).agentProxy?.gh)
        #expect(gh == AgentProxySettings.GH(agent: "logan-shire-codex", sessionAgents: ["s1": "claude"], auditLog: "/tmp/x.log"))
        let empty = try #require(try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"agentProxy":{"gh":{}}}"#.utf8)).agentProxy?.gh)
        #expect(empty == AgentProxySettings.GH())
        let configuration = try #require(AgentProxyHost.configuration(empty, log: nil))
        #expect(configuration == MCPServer.Configuration(repositories: ["AttilaTheFun/*"], agent: "agent"), "AttilaTheFun/*, as logan-shire-agent")
        #expect(AgentProxyHost.configuration(AgentProxySettings.GH(agent: "logan-shire-gpt"), log: nil) == nil)
        let some = try #require(AgentProxyHost.configuration(AgentProxySettings.GH(sessionAgents: ["a": "logan-shire-claude", "b": "gpt"]), log: nil))
        #expect(some.sessionAgents == ["a": "claude"], "an app agent-token doesn't know is passed over")
    }

    @Test func theAuditLogIsInTheServersLogsFolder() {
        let data = URL(fileURLWithPath: "/data")
        #expect(AgentProxyHost.Places(dataDirectory: data, egressLog: "/Volumes/Visor/Logs/Visor-egress.log").ghAuditLog
                == "/Volumes/Visor/Logs/Visor-gh.log", "a Mac's: beside its other logs")
        #expect(AgentProxyHost.Places(dataDirectory: data).ghAuditLog == "/data/agent-proxy/gh.log")
        #expect(AgentProxyHost.Places(dataDirectory: data, ghAuditLog: "/elsewhere.log").ghAuditLog == "/elsewhere.log")
    }

    /// `agentProxy.gh` end to end: gh_mcp at `/mcp/gh`, behind the sessions'
    /// token, each session its own app, its calls in the audit log.
    @Test func agentProxyServesGhMCPAtMCPGh() throws {
        let data = try folder()
        let audit = data.appendingPathComponent("Logs/Visor-gh.log").path
        let script = data.appendingPathComponent("agent-token").path
        try "#!/bin/sh\necho \"$@\" >> \"\(data.path)/calls\"\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let secrets = MemorySecrets()
        secrets.set("agent-proxy/mcp/token", "sessions-token")
        let places = AgentProxyHost.Places(dataDirectory: data, egressLog: data.appendingPathComponent("Logs/Visor-egress.log").path)
        let lines = Mutex<[String]>([])
        var running: AgentProxyHost.Running?
        var port = 0
        func settings(_ agents: [String: String]) -> AgentProxySettings {
            AgentProxySettings(mcp: .init(port: port), gh: .init(agentToken: script, sessionAgents: agents))
        }
        for _ in 0..<20 where running == nil {
            port = Int.random(in: 20000...45000)
            try JSONEncoder().encode(["agentProxy": settings(["s-claude": "logan-shire-claude"])]).write(to: places.settingsFile)
            running = AgentProxyHost.start(settings(["s-claude": "logan-shire-claude"]), places: places, secrets: secrets, version: "test",
                                           log: { line in lines.withLock { $0.append(line) } })
            if running?.complete == false { running?.stop(); running = nil }
        }
        let proxy = try #require(running)
        defer { proxy.stop() }
        #expect(lines.withLock { $0.contains { $0.contains("/mcp/gh (in-process)") } }, "\(lines.withLock { $0 })")
        let listed = ask(UInt16(port), "/mcp/gh", token: "sessions-token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(listed.status == "200")
        let tools = (try? JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any])
            .flatMap { ($0["result"] as? [String: Any])?["tools"] as? [[String: Any]] }
        #expect(tools?.count == 35 && tools?.first?["name"] as? String == "git_push")
        #expect(ask(UInt16(port), "/mcp/gh", token: nil, body: "{}").status == "401")

        let initialize = #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        #expect(ask(UInt16(port), "/mcp/gh", token: "sessions-token", body: initialize, extra: ["CLIENT_ID: s-claude"]).body
            .contains("logan-shire-claude GitHub App"))
        #expect(ask(UInt16(port), "/mcp/gh", token: "sessions-token", body: initialize, extra: ["CLIENT_ID: s-new"]).body
            .contains("logan-shire-agent GitHub App"))
        // A session given its app in settings.json: taken at its next call, no restart.
        try JSONEncoder().encode(["agentProxy": settings(["s-new": "codex"])]).write(to: places.settingsFile)
        #expect(ask(UInt16(port), "/mcp/gh", token: "sessions-token", body: initialize, extra: ["CLIENT_ID: s-new"]).body
            .contains("logan-shire-codex GitHub App"))

        // A call: agent-token asked as gh_mcp asked it, its failure the call's, a line of the audit log.
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pr_list","arguments":{"repo":"AttilaTheFun/visor"}}}"#
        let called = ask(UInt16(port), "/mcp/gh", token: "sessions-token", body: call, extra: ["CLIENT_ID: s-new"])
        #expect(called.body.contains(#""isError":true"#) && called.body.contains("agent-token gave codex no token"), "\(called.body)")
        #expect(try String(contentsOfFile: data.path + "/calls", encoding: .utf8) == "token codex --owner AttilaTheFun\n")
        let logged = try String(contentsOfFile: audit, encoding: .utf8).split(separator: "\n")
        #expect(logged.first?.contains(" gh_mcp 0.1.0 in agent-proxy at /mcp/gh") == true, "\(logged)")
        #expect(logged.last?.contains(" s-new@visor pr_list AttilaTheFun/visor failed: agent-token gave codex no token") == true, "\(logged)")
    }
}
