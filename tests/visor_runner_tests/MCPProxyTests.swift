// The Runner's MCP proxy (docs/co-tenancy.md): a call with any of its
// servers' tokens goes on to its endpoint with the secret headers the
// Runner keeps, and without a token or for no endpoint, it is refused; the
// endpoints are read as they are set now. The endpoint is a small listener
// of the test's own.

import CVisorPOSIX
import Foundation
import Synchronization
import VisorRunner
import Testing

/// An MCP endpoint played here: what each request said, and an answer.
private final class FakeEndpoint: Sendable {
    let port: UInt16
    private let listener: Int32
    let requests = Mutex<[String]>([])
    /// The body of every answer.
    private let answer: String

    init?(answer: String = #"{"jsonrpc":"2.0","id":1,"result":{}}"#) {
        self.answer = answer
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...45000)
            let socket = visor_listen(port, 0)
            if socket >= 0 {
                self.port = port
                listener = socket
                Thread.detachNewThread { [self] in serve() }
                return
            }
        }
        return nil
    }

    private func serve() {
        while true {
            let connection = visor_accept(listener)
            if connection < 0 { return }
            Thread.detachNewThread { [self] in
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while request.range(of: Data("\r\n\r\n".utf8)) == nil || !request.suffix(2).elementsEqual(Data("}\n".utf8)) && request.count < 4096 {
                    let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    request.append(contentsOf: buffer[0..<count])
                    if let end = request.range(of: Data("\r\n\r\n".utf8)), request.count > end.upperBound { break }
                }
                requests.withLock { $0.append(String(decoding: request, as: UTF8.self)) }
                let body = answer
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                _ = Array(response.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                close(connection)
            }
        }
    }

    func stop() {
        visor_shutdown(listener)
        close(listener)
    }
}

@Suite final class MCPProxyTests {
    /// A proxy on a free port, serving these endpoints, with each one's
    /// `Authorization` its secret.
    private func proxy(_ endpoints: Setting<[MCPProxy.Endpoint]>) throws -> (proxy: MCPProxy, port: UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...45000)
            if let proxy = MCPProxy(port: port, endpoints: { endpoints.value }, admits: { $0 == "one-token" }, secret: { name, header in
                header == "Authorization" ? "Bearer \(name)-secret" : nil
            }) {
                proxy.start()
                return (proxy, port)
            }
        }
        try Test.cancel("no free port")
    }

    /// A tool withheld (one whose answer holds a credential) is left out of
    /// the tools listed, and a call of it is refused here, never passed on;
    /// the endpoint's other tools are listed and called as ever.
    @Test func testAWithheldToolIsNeitherListedNorCalled() throws {
        let tools = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"whoami"},{"name":"github_token"}]}}"#
        let endpoint = try #require(FakeEndpoint(answer: tools))
        defer { endpoint.stop() }
        let endpoints = Setting([MCPProxy.Endpoint(name: "keymaster", url: "http://127.0.0.1:\(endpoint.port)/mcp",
                                                   secretHeaders: ["Authorization"], withheldTools: ["github_token"])])
        let (started, port) = try proxy(endpoints)
        defer { started.stop() }
        let url = "http://127.0.0.1:\(port)/mcp/keymaster"
        func post(_ body: String) throws -> (body: String, status: String) {
            try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "-H", "Content-Type: application/json", "--data-binary", body, url])
        }

        let listed = try post(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(listed.status == "200")
        let names = try #require((try JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [String: Any]).flatMap {
            (($0["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        })
        #expect(names == ["whoami"])

        let refused = try post(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"github_token","arguments":{}}}"#)
        #expect(refused.status == "200")
        #expect(refused.body.contains(#""id":7"#) && refused.body.contains("-32601"), Comment(rawValue: refused.body))
        #expect((endpoint.requests.withLock { $0.count }) == 1, "the call never reached the endpoint")

        #expect((try post(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"whoami"}}"#).status) == "200")
        #expect((endpoint.requests.withLock { $0.count }) == 2)
        #expect(try #require(endpoint.requests.withLock { $0.last }).contains("Authorization: Bearer keymaster-secret\r\n"))

        // Failing closed: what can't be read as JSON-RPC, or a call that
        // names no tool plainly, goes no further.
        for body in ["not json", "[]", "[1]", #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":7}}"#] {
            let answer = try post(body)
            #expect(answer.body.contains("-32600") || answer.body.contains("-32601"), "\(body): \(answer.body)")
        }
        #expect((endpoint.requests.withLock { $0.count }) == 2, "none reached the endpoint")
        // A key given twice: refused, or passed on as read here, once.
        _ = try post(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"whoami","name":"github_token"}}"#)
        let sent = endpoint.requests.withLock { $0 }
        #expect(sent.count == 2 || !(sent.last ?? "").contains("github_token"), Comment(rawValue: sent.last ?? ""))
    }

    /// An endpoint kept before tools could be withheld reads with none.
    @Test func testAnEndpointKeptBeforeWithholdingWithholdsNothing() throws {
        let kept = #"{"name":"gh","url":"http://127.0.0.1:7470/mcp","headers":{"CLIENT_ID":"$SESSION_ID"},"secretHeaders":["API_KEY"]}"#
        let endpoint = try JSONDecoder().decode(MCPProxy.Endpoint.self, from: Data(kept.utf8))
        #expect(endpoint.withheldTools == [])
        #expect(endpoint.secretHeaders == ["API_KEY"])
    }

    @Test func testACallWithAServersTokenGoesOnWithTheSecretHeaders() throws {
        let endpoint = try #require(FakeEndpoint())
        defer { endpoint.stop() }
        let endpoints = Setting([MCPProxy.Endpoint(name: "gh", url: "http://127.0.0.1:\(endpoint.port)/mcp", secretHeaders: ["Authorization"])])
        var proxy: MCPProxy?
        var port: UInt16 = 0
        for _ in 0..<20 where proxy == nil {
            port = UInt16.random(in: 20000...45000)
            proxy = MCPProxy(port: port, endpoints: { endpoints.value }, admits: { ["one-token", "two-token"].contains($0) }) { name, header in
                name == "gh" && header == "Authorization" ? "Bearer gh-secret" : nil
            }
        }
        let started = try #require(proxy)
        started.start()
        defer { started.stop() }

        let answered = try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "-H", "X-Visor-Session: s1", "-H", "Content-Type: application/json",
                                 "--data-binary", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, "http://127.0.0.1:\(port)/mcp/gh"])
        #expect(answered.status == "200")
        #expect(answered.body == (#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
        let seen = try #require(endpoint.requests.withLock { $0.first })
        #expect(seen.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        #expect(seen.contains("Authorization: Bearer gh-secret\r\n"))
        #expect(seen.contains("X-Visor-Session: s1\r\n"))
        #expect(!seen.contains("one-token"), "a server's token stops at the proxy")
        #expect(seen.contains(#""method":"tools/list""#))

        // Another server's token goes on too.
        #expect((try curl(["-X", "POST", "-H", "X-Visor-Proxy: two-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status) == "200")
        #expect((try curl(["-X", "POST", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status) == "401")
        #expect((try curl(["-X", "POST", "-H", "X-Visor-Proxy: three-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status) == "401")
        #expect((try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/other"]).status) == "404")
        // The endpoints as they are set now: one taken away is no more.
        endpoints.value = []
        #expect((try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status) == "404")
        #expect((endpoint.requests.withLock { $0.count }) == 2)
    }
}
