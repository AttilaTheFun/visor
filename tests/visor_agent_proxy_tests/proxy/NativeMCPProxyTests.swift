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
    /// `agentSession` says), each endpoint's `API_KEY` its secret.
    private func proxy(_ endpoints: [NativeMCPProxy.Endpoint], maxConnections: Int = NativeMCPProxy.defaultMaxConnections,
                       agentSession: (@Sendable (String) async -> String?)? = nil) throws -> NativeMCPProxy {
        for _ in 0..<20 {
            if let proxy = NativeMCPProxy(port: UInt16.random(in: 20000...45000), endpoints: { endpoints }, admits: { $0 == "one-token" },
                                          secret: { name, header in header == "API_KEY" ? "\(name)-secret" : nil },
                                          agentSession: agentSession, maxConnections: maxConnections) {
                proxy.start()
                return proxy
            }
        }
        throw XCTSkip("no free port")
    }

    /// An HTTP request to the proxy, and its status and body.
    private func ask(_ port: UInt16, _ path: String, token: String?, body: String = "{}", extra: [String] = []) throws -> (status: String, body: String) {
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
                               extra: ["CLIENT_ID: s-other", "client-id: s-other", "X-Title: the-callers-own", "API_KEY: the-callers-own"])
        XCTAssertEqual(answered.status, "200")
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.contains("CLIENT_ID: s-container\r\n"), seen)
        XCTAssertEqual(seen.components(separatedBy: "CLIENT_ID").count, 2, "once: \(seen)")
        XCTAssertFalse(seen.contains("s-other"), "the caller's CLIENT_ID never goes on: \(seen)")
        XCTAssertFalse(seen.contains("the-callers-own"), "nor its word for a session's header, nor its secret: \(seen)")
        XCTAssertTrue(seen.contains("API_KEY: nimbus-secret\r\n") && seen.contains("X-Fleet: mini\r\n"), seen)
        XCTAssertFalse(seen.contains("agent.own.token"), "the agent's token stops at the proxy")
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
        XCTAssertEqual(NativeMCPProxy.containerServers, ["nimbus"])
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let names = ["gh", "oss", "shireworks", "nimbus"]
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
        for name in names {
            XCTAssertEqual(try ask(proxy.port, "/mcp/\(name)", token: "one-token").status, "200", "native: \(name)")
        }
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 5)
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
