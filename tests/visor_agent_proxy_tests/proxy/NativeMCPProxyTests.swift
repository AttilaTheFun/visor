// The native sessions' MCP proxy (NativeMCPProxy, moved from MultiPass's MCPProxy and its tests): a call with the
// sessions' token goes on to its endpoint with the secret headers agent-proxy keeps; without the token, or for no
// endpoint, it's refused; a withheld tool is neither listed nor called; a Sessions container agent's own token goes on
// as its session's, and no other. The endpoint is a FakeEndpoint (TestServers).

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy
import XCTest

final class NativeMCPProxyTests: XCTestCase {
    /// A proxy on a free loopback port, serving `endpoints`, admitting `one-token` (and a container agent's own token as
    /// `agentSession` says, once `agentTokenCheck` lets it be asked), each endpoint's `API_KEY` its secret.
    private func proxy(_ endpoints: [NativeMCPProxy.Endpoint], maxConnections: Int = NativeMCPProxy.defaultMaxConnections,
                       maxVouches: Int = NativeMCPProxy.defaultMaxVouches,
                       agentSession: (@Sendable (String) async -> String?)? = nil,
                       agentTokenCheck: (@Sendable (String) -> Bool)? = nil,
                       log: (@Sendable (String) -> Void)? = nil) throws -> NativeMCPProxy {
        for _ in 0..<20 {
            if let proxy = NativeMCPProxy(port: UInt16.random(in: 20000...45000), endpoints: { endpoints }, admits: { $0 == "one-token" },
                                          secret: { name, header in header == "API_KEY" ? "\(name)-secret" : nil },
                                          agentSession: agentSession, agentTokenCheck: agentTokenCheck, maxConnections: maxConnections,
                                          maxVouches: maxVouches, log: log) {
                proxy.start()
                return proxy
            }
        }
        throw XCTSkip("no free port")
    }

    /// An HTTP request to the proxy, and its status and body.
    private func ask(_ port: UInt16, _ path: String, token: String?, body: String = "{}", extra: [String] = []) throws -> (status: String, body: String) {
        try Self.ask(port, path, token: token, body: body, extra: extra)
    }

    /// The same, from any thread.
    private static func ask(_ port: UInt16, _ path: String, token: String?, body: String = "{}", extra: [String] = []) throws
        -> (status: String, body: String) {
        let connection = agent_proxy_connect_tcp("127.0.0.1", port)
        guard connection >= 0 else { throw XCTSkip("the proxy can't be reached") }
        defer { close(connection) }
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { head += "X-Visor-Proxy: \(token)\r\n" }
        for line in extra { head += line + "\r\n" }
        let request = Array((head + "\r\n" + body).utf8)
        _ = request.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: answer, as: UTF8.self)
        let status = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return (status, bodyText)
    }

    func testACallWithTheSessionsTokenGoesOnWithTheSecretHeaders() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "gh", url: "http://127.0.0.1:\(endpoint.port)/mcp", secretHeaders: ["API_KEY"])])
        defer { proxy.stop() }
        let answered = try ask(proxy.port, "/mcp/gh", token: "one-token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                               extra: ["CLIENT_ID: s1", "API_KEY: the-callers-own"])
        XCTAssertEqual(answered.status, "200")
        XCTAssertEqual(answered.body, #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        XCTAssertTrue(seen.contains("API_KEY: gh-secret\r\n"))
        XCTAssertFalse(seen.contains("the-callers-own"), "the caller's own secret header never goes on beside agent-proxy's")
        XCTAssertTrue(seen.contains("CLIENT_ID: s1\r\n"), "the session's plain headers go on")
        XCTAssertFalse(seen.contains("one-token"), "the sessions' token stops at the proxy")
        // No token, another token, no such endpoint.
        XCTAssertEqual(try ask(proxy.port, "/mcp/gh", token: nil).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/mcp/gh", token: "two-token").status, "401")
        XCTAssertEqual(try ask(proxy.port, "/mcp/other", token: "one-token").status, "404")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1)
    }

    /// A Sessions container agent's call (0.72.1): not the sessions' token, its agent's own, which the server says is
    /// its session's. It goes on as that session's whatever CLIENT_ID it sent (an endpoint's `$SESSION_ID` filled with
    /// it, a session header agent-proxy can't fill left out, never the caller's word), with the endpoint's plain and
    /// secret headers added exactly as for a native session's call, and the token stops here. Any other token
    /// (another's, an expired or a forged one: the server says it's no one's) is refused before anything is passed on;
    /// only a JWT's shape is asked about, and the sessions' token never is.
    func testAContainerAgentsOwnTokenGoesOnAsItsSession() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let asked = Lines()
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "nimbus", url: "http://127.0.0.1:\(endpoint.port)/mcp",
                                                       headers: ["CLIENT_ID": "$SESSION_ID", "X-Title": "$SESSION_TITLE", "X-Fleet": "mini"],
                                                       secretHeaders: ["API_KEY"])],
                              agentSession: { token in
                                  asked.add(token)
                                  return token == "agent.own.token" ? "s-container" : nil
                              })
        defer { proxy.stop() }
        let answered = try ask(proxy.port, "/mcp/nimbus", token: "agent.own.token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                               extra: ["CLIENT_ID: s-other", "client-id: s-other", "X-Title: the-callers-own", "API_KEY: the-callers-own",
                                       "Authorization: Bearer agent.own.token"])
        XCTAssertEqual(answered.status, "200")
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.contains("CLIENT_ID: s-container\r\n"), seen)
        XCTAssertEqual(seen.components(separatedBy: "CLIENT_ID").count, 2, "once: \(seen)")
        XCTAssertFalse(seen.contains("s-other"), "the caller's CLIENT_ID never goes on: \(seen)")
        XCTAssertFalse(seen.contains("the-callers-own"), "nor its word for a session's header, nor its secret: \(seen)")
        XCTAssertTrue(seen.contains("API_KEY: nimbus-secret\r\n") && seen.contains("X-Fleet: mini\r\n"), seen)
        XCTAssertFalse(seen.contains("agent.own.token"), "the agent's token stops at the proxy")
        XCTAssertFalse(seen.lowercased().contains("authorization"), "its bearer (the same token, for Claude Code) too: \(seen)")
        for token in ["expired.or.forged", "not-a-jwt", ""] {
            XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: token).status, "401", token)
        }
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: nil).status, "401")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1, "nothing refused is passed on")
        XCTAssertEqual(asked.all, ["agent.own.token", "expired.or.forged"], "only a JWT's shape is asked about")
        // A native session's call, through Visor's server, as before: never asked about, and the endpoint's headers
        // added just as they were for the container's agent.
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: "one-token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                               extra: ["CLIENT_ID: s-container"]).status, "200")
        XCTAssertEqual(asked.all.count, 2)
        let native = try XCTUnwrap(endpoint.requests.withLock { $0.last })
        XCTAssertTrue(native.contains("CLIENT_ID: s-container\r\n"), native)
        func added(_ request: String) -> [String] {
            request.components(separatedBy: "\r\n").filter { $0.hasPrefix("API_KEY:") || $0.hasPrefix("X-Fleet:") || $0.hasPrefix("CLIENT_ID:") }.sorted()
        }
        XCTAssertEqual(added(seen), added(native), "the same headers on, the container's call or the native one")
    }

    /// A container agent's token reaches the servers containers are given alone (Logan, 25 Nov 2026: Nimbus's; gh is
    /// the gh CLI through the GitHub gate, oss is retired, Shireworks' is Nimbus's): any other path is 403, its server
    /// never called. A native session's call reaches each, as before.
    func testAContainerAgentReachesNimbusAlone() throws {
        XCTAssertEqual(NativeMCPProxy.containerServers, ["nimbus", "nimbus-devices"])
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let names = ["gh", "oss", "shireworks", "nimbus", "nimbus-devices"]
        let proxy = try proxy(names.map { NativeMCPProxy.Endpoint(name: $0, url: "http://127.0.0.1:\(endpoint.port)/mcp") },
                              agentSession: { $0 == "agent.own.token" ? "s-container" : nil })
        defer { proxy.stop() }
        for name in ["gh", "oss", "shireworks"] {
            for path in ["/mcp/\(name)", "/mcp/\(name)/x", "/mcp/\(name)?a=b"] {
                XCTAssertEqual(try ask(proxy.port, path, token: "agent.own.token").status, "403", path)
            }
        }
        XCTAssertEqual(try ask(proxy.port, "/other", token: "agent.own.token").status, "403")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 0, "nothing refused is passed on")
        XCTAssertEqual(try ask(proxy.port, "/mcp/gh", token: "someone.elses.token").status, "401", "a token that's no one's: 401 first")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: "agent.own.token").status, "200")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus-devices", token: "agent.own.token").status, "200")
        for name in names {
            XCTAssertEqual(try ask(proxy.port, "/mcp/\(name)", token: "one-token").status, "200", "native: \(name)")
        }
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 7)
    }

    /// NCH's check of #536: the server's word on a container agent's token is waited for (up to ten seconds) while the
    /// call holds one of the proxy's places, so forged tokens could fill them. A token is checked here first, at once
    /// (`agentTokenCheck`: the server's keys): one that fails (forged, expired, another server's) is refused with no
    /// wait, and the server is never asked; one that passes is asked as before.
    func testAForgedTokenIsRefusedAtOnce() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let asked = Lines()
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "nimbus", url: "http://127.0.0.1:\(endpoint.port)/mcp")],
                              agentSession: { token in
                                  asked.add(token)
                                  // A server slow to say, that would say yes to anything.
                                  if token != "agent.own.token" { try? await Task.sleep(for: .seconds(5)) }
                                  return "s-container"
                              },
                              agentTokenCheck: { $0 == "agent.own.token" })
        defer { proxy.stop() }
        for forged in ["forged.jwt.token", "expired.jwt.token"] {
            let start = Date()
            XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: forged).status, "401", forged)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, "refused with no wait: \(forged)")
        }
        XCTAssertEqual(asked.all, [], "the server is never asked about them")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 0)
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: "agent.own.token").status, "200")
        XCTAssertEqual(asked.all, ["agent.own.token"])
    }

    /// A JWT's shape, its payload `claims` (unsigned: the proxy reads its claims only to say why it refused it).
    private static func jwt(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2lnbmF0dXJlLW9mLWl0cw"
    }

    /// A refused call (401) is said in the log, why, and whose (the agent its token claims), never its token: once for
    /// each agent and reason, until a call of that agent is taken again. No header, an expired token, one not this
    /// server's, one of an agent not running now: each said (on the Mini, 0.72.3, Nimbus's 401s said nothing).
    func testARefusalIsLoggedOnceForEachAgentAndReasonNeverWithItsToken() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let later = Int(Date().timeIntervalSince1970) + 3600
        let past = Int(Date().timeIntervalSince1970) - 60
        let live = Self.jwt(#"{"agent":"agent-a","exp":\#(later)}"#)
        let expired = Self.jwt(#"{"agent":"agent-a","exp":\#(past)}"#)
        let gone = Self.jwt(#"{"agent":"agent-b","exp":\#(later)}"#)
        let forged = Self.jwt(#"{"agent":"agent-c","exp":\#(later)}"#)
        let lines = Lines()
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "nimbus", url: "http://127.0.0.1:\(endpoint.port)/mcp")],
                              agentSession: { $0 == live ? "s-container" : nil },
                              agentTokenCheck: { !NativeMCPProxy.hasEnded($0) && $0 != forged },
                              log: { lines.add($0) })
        defer { proxy.stop() }
        for _ in 0..<3 {
            XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: expired).status, "401")
        }
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: gone).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: forged).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/register", token: nil).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/register", token: nil).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: "not-a-jwt").status, "401")
        XCTAssertEqual(lines.all.count, 5, "once each: \(lines.all)")
        func said(_ words: String...) -> Int { lines.all.filter { line in words.allSatisfy(line.contains) }.count }
        XCTAssertEqual(said("/mcp/nimbus", "agent agent-a", "(401)", "expired"), 1, "\(lines.all)")
        XCTAssertEqual(said("agent agent-b", "names no agent running"), 1, "\(lines.all)")
        XCTAssertEqual(said("agent agent-c", "isn't one of this server's"), 1, "\(lines.all)")
        XCTAssertEqual(said("no X-Visor-Proxy header"), 1, "\(lines.all)")
        XCTAssertEqual(said("neither the sessions'"), 1, "\(lines.all)")
        // A call of agent-a's taken: its refusal said again when it comes again; the others not.
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: live).status, "200")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: expired).status, "401")
        XCTAssertEqual(try ask(proxy.port, "/mcp/nimbus", token: gone).status, "401")
        XCTAssertEqual(said("agent agent-a", "expired"), 2, "\(lines.all)")
        XCTAssertEqual(lines.all.count, 6)
        // Never a token, nor any part of one.
        for token in [live, expired, gone, forged, "not-a-jwt"] {
            for part in token.split(separator: ".") {
                XCTAssertFalse(lines.all.contains { $0.contains(part) }, "\(part) in \(lines.all)")
            }
        }
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1, "nothing refused is passed on")
    }

    /// The caller's word, as the log shows it: lower-case letters, digits and hyphens, 64 at most.
    func testARefusalShowsOnlyTheClaimedAgentsPlainCharacters() {
        XCTAssertEqual(NativeMCPProxy.shown("Agent-1\r\nforged: line"), "agent-1forgedline")
        XCTAssertEqual(NativeMCPProxy.shown(String(repeating: "a", count: 100)).count, 64)
        XCTAssertEqual(NativeMCPProxy.claimedAgent(Self.jwt(#"{"agent":"9250DAF8-03ff"}"#)), "9250daf8-03ff")
        XCTAssertEqual(NativeMCPProxy.claimedAgent("not.a.jwt"), "")
        XCTAssertTrue(NativeMCPProxy.hasEnded(Self.jwt(#"{"exp":1}"#)))
        XCTAssertFalse(NativeMCPProxy.hasEnded(Self.jwt(#"{"exp":\#(Int(Date().timeIntervalSince1970) + 60)}"#)))
        XCTAssertFalse(NativeMCPProxy.hasEnded("a.b.c"))
    }

    /// At most `maxVouches` calls wait on the server's word at once (eight); another is refused at once (503), and one
    /// is asked again once a place is given back.
    func testCallsPastTheVouchesCapAreRefusedAtOnce() throws {
        XCTAssertEqual(NativeMCPProxy.defaultMaxVouches, 8)
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let waiting = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "nimbus", url: "http://127.0.0.1:\(endpoint.port)/mcp")], maxVouches: 1,
                              agentSession: { _ in
                                  waiting.signal()
                                  // The server's answer held until the test lets it go.
                                  await withCheckedContinuation { (said: CheckedContinuation<Void, Never>) in
                                      DispatchQueue.global().async {
                                          answer.wait()
                                          said.resume()
                                      }
                                  }
                                  return "s-container"
                              },
                              agentTokenCheck: { _ in true })
        defer { proxy.stop() }
        let port = proxy.port
        let first = Locked<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let status = try? Self.ask(port, "/mcp/nimbus", token: "agent.own.token").status
            first.withLock { $0 = status }
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success, "the first call waits on the server")
        let start = Date()
        XCTAssertEqual(try ask(port, "/mcp/nimbus", token: "agent.own.token").status, "503")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "refused with no wait")
        answer.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(first.withLock { $0 }, "200")
        // Its place given back: the next is asked.
        answer.signal()
        XCTAssertEqual(try ask(port, "/mcp/nimbus", token: "agent.own.token").status, "200")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 2)
    }

    /// An endpoint kept as MultiPass's runner.json kept it (CLIENT_ID: $SESSION_ID) leaves CLIENT_ID to the session, so
    /// each session reaches the MCP server as itself, never as the literal `$SESSION_ID`; its other plain headers win.
    func testAnEndpointsSessionHeaderIsTheSessions() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "shireworks", url: "http://127.0.0.1:\(endpoint.port)/mcp",
                                                       headers: ["CLIENT_ID": "$SESSION_ID", "X-Fleet": "mini"], secretHeaders: ["API_KEY"])])
        defer { proxy.stop() }
        let answered = try ask(proxy.port, "/mcp/shireworks", token: "one-token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                               extra: ["CLIENT_ID: s1", "X-Fleet: the-callers-own"])
        XCTAssertEqual(answered.status, "200")
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.contains("CLIENT_ID: s1\r\n"), "the session's own CLIENT_ID goes on")
        XCTAssertFalse(seen.contains("$SESSION_ID"), "never the variable as written")
        XCTAssertTrue(seen.contains("X-Fleet: mini\r\n"))
        XCTAssertFalse(seen.contains("the-callers-own"), "the endpoint's other plain headers stand in for the caller's")
    }

    func testAWithheldToolIsNeitherListedNorCalled() throws {
        let tools = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"whoami"},{"name":"github_token"}]}}"#
        let endpoint = try XCTUnwrap(FakeEndpoint(answer: tools))
        defer { endpoint.stop() }
        let proxy = try proxy([NativeMCPProxy.Endpoint(name: "oss", url: "http://127.0.0.1:\(endpoint.port)/mcp", secretHeaders: ["API_KEY"],
                                                       withheldTools: ["github_token"])])
        defer { proxy.stop() }
        let listed = try ask(proxy.port, "/mcp/oss", token: "one-token", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(listed.status, "200")
        let names = (try JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any]).flatMap {
            (($0["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(names, ["whoami"])
        let refused = try ask(proxy.port, "/mcp/oss", token: "one-token",
                              body: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"github_token","arguments":{}}}"#)
        XCTAssertTrue(refused.body.contains(#""id":7"#) && refused.body.contains("-32601"), refused.body)
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1, "the withheld call never reached the endpoint")
        for body in ["not json", "[]", "[1]", #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":7}}"#] {
            let answer = try ask(proxy.port, "/mcp/oss", token: "one-token", body: body)
            XCTAssertTrue(answer.body.contains("-32600") || answer.body.contains("-32601"), "\(body): \(answer.body)")
        }
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1, "none reached the endpoint")
    }

    /// A listing answered as an SSE stream, or chunked, is filtered as a plain JSON one is (NCH, 2026-11-18).
    func testAWithheldToolIsKeptFromAStreamedOrChunkedListing() {
        let message = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"whoami"},{"name":"github_token"}]}}"#
        let stream = "event: message\ndata: \(message)\n\n"
        let streamed = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(stream.utf8.count)\r\n\r\n\(stream)".utf8)
        let chunks = String(message.utf8.count - 10, radix: 16) + "\r\n" + message.dropLast(10) + "\r\n"
            + String(10, radix: 16) + "\r\n" + message.suffix(10) + "\r\n0\r\n\r\n"
        let chunked = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(chunks)".utf8)
        for answer in [streamed, chunked] {
            let text = String(decoding: NativeMCPProxy.withoutTools(["github_token"], in: answer), as: UTF8.self)
            XCTAssertTrue(text.contains("whoami"), text)
            XCTAssertFalse(text.contains("github_token"), text)
            XCTAssertFalse(text.lowercased().contains("transfer-encoding"), text)
            let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
            XCTAssertTrue(text.contains("Content-Length: \(body.utf8.count)\r\n"), text)
        }
        // Cut short: as it came.
        let cut = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\nff\r\n{".utf8)
        XCTAssertEqual(NativeMCPProxy.withoutTools(["github_token"], in: cut), cut)
    }

    /// A chunked request is refused (its body is read by Content-Length alone), and calls past the cap are too.
    func testAChunkedCallAndOnePastTheCapAreRefused() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint(answer: "{}"))
        defer { endpoint.stop() }
        let endpoints = [NativeMCPProxy.Endpoint(name: "gh", url: "http://127.0.0.1:\(endpoint.port)/mcp")]
        let proxy = try proxy(endpoints)
        defer { proxy.stop() }
        XCTAssertEqual(try ask(proxy.port, "/mcp/gh", token: "one-token", extra: ["Transfer-Encoding: chunked"]).status, "411")
        let full = try self.proxy(endpoints, maxConnections: 0)
        defer { full.stop() }
        XCTAssertEqual(try ask(full.port, "/mcp/gh", token: "one-token").status, "503")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 0, "neither reached the endpoint")
    }

    /// MultiPass's runner.json endpoints read as they were kept (Visor's, on the mini).
    func testMultiPasssEndpointsRead() throws {
        let kept = #"{"name":"gh","url":"http://127.0.0.1:7470/mcp","headers":{"CLIENT_ID":"$SESSION_ID"},"secretHeaders":["API_KEY"]}"#
        let endpoint = try JSONDecoder().decode(NativeMCPProxy.Endpoint.self, from: Data(kept.utf8))
        XCTAssertEqual(endpoint.withheldTools, [])
        XCTAssertEqual(endpoint.secretHeaders, ["API_KEY"])
    }
}
