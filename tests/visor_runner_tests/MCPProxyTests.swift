// The Runner's MCP proxy (docs/co-tenancy.md): a call with any of its
// servers' tokens goes on to its endpoint with the secret headers the
// Runner keeps, and without a token or for no endpoint, it is refused; the
// endpoints are read as they are set now. The endpoint is a small listener
// of the test's own.

import CVisorPOSIX
import Foundation
import Synchronization
import VisorRunner
import XCTest

/// An MCP endpoint played here: what each request said, and an answer.
private final class FakeEndpoint: Sendable {
    let port: UInt16
    private let listener: Int32
    let requests = Mutex<[String]>([])

    init?() {
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
                let body = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
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

final class MCPProxyTests: XCTestCase {
    func testACallWithAServersTokenGoesOnWithTheSecretHeaders() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
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
        let started = try XCTUnwrap(proxy)
        started.start()
        defer { started.stop() }

        let answered = try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "-H", "X-Visor-Session: s1", "-H", "Content-Type: application/json",
                                 "--data-binary", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, "http://127.0.0.1:\(port)/mcp/gh"])
        XCTAssertEqual(answered.status, "200")
        XCTAssertEqual(answered.body, #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        XCTAssertTrue(seen.contains("Authorization: Bearer gh-secret\r\n"))
        XCTAssertTrue(seen.contains("X-Visor-Session: s1\r\n"))
        XCTAssertFalse(seen.contains("one-token"), "a server's token stops at the proxy")
        XCTAssertTrue(seen.contains(#""method":"tools/list""#))

        // Another server's token goes on too.
        XCTAssertEqual(try curl(["-X", "POST", "-H", "X-Visor-Proxy: two-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status, "200")
        XCTAssertEqual(try curl(["-X", "POST", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status, "401")
        XCTAssertEqual(try curl(["-X", "POST", "-H", "X-Visor-Proxy: three-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status, "401")
        XCTAssertEqual(try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/other"]).status, "404")
        // The endpoints as they are set now: one taken away is no more.
        endpoints.value = []
        XCTAssertEqual(try curl(["-X", "POST", "-H", "X-Visor-Proxy: one-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status, "404")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 2)
    }
}
