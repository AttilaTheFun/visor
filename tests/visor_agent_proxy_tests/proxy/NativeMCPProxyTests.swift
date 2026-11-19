// The native sessions' MCP proxy (NativeMCPProxy, moved from MultiPass's MCPProxy and its tests): a call with the
// sessions' token goes on to its endpoint with the secret headers agent-proxy keeps; without the token, or for no
// endpoint, it's refused; a withheld tool is neither listed nor called. The endpoint is a FakeEndpoint (TestServers).

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy
import XCTest

final class NativeMCPProxyTests: XCTestCase {
    /// A proxy on a free loopback port, serving `endpoints`, admitting `one-token`, each endpoint's `API_KEY` its secret.
    private func proxy(_ endpoints: [NativeMCPProxy.Endpoint], maxConnections: Int = NativeMCPProxy.defaultMaxConnections) throws -> NativeMCPProxy {
        for _ in 0..<20 {
            if let proxy = NativeMCPProxy(port: UInt16.random(in: 20000...45000), endpoints: { endpoints }, admits: { $0 == "one-token" },
                                          secret: { name, header in header == "API_KEY" ? "\(name)-secret" : nil },
                                          maxConnections: maxConnections) {
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
