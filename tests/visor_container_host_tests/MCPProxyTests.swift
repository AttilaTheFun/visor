// The host's MCP proxy for a container's agents (docs/co-tenancy.md): a
// call with the container's token goes on to its endpoint with the secret
// headers the host keeps, and without the token or for no endpoint, it is
// refused. The endpoint is a small listener of the test's own.

import CVisorPOSIX
import Foundation
import Synchronization
@testable import VisorContainerHost
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

/// `curl` with these arguments: what came back, and the HTTP status.
private func curl(_ arguments: [String]) throws -> (body: String, status: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-s", "-m", "10", "-w", "\n%{http_code}"] + arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let lines = text.components(separatedBy: "\n")
    return (lines.dropLast().joined(separator: "\n"), lines.last ?? "")
}

final class MCPProxyTests: XCTestCase {
    func testACallWithTheTokenGoesOnWithTheSecretHeaders() throws {
        let endpoint = try XCTUnwrap(FakeEndpoint())
        defer { endpoint.stop() }
        let spec = ServerSpec.Endpoint(name: "gh", url: "http://127.0.0.1:\(endpoint.port)/mcp", headers: [:], secretHeaders: ["Authorization"])
        var proxy: MCPProxy?
        var port: UInt16 = 0
        for _ in 0..<20 where proxy == nil {
            port = UInt16.random(in: 20000...45000)
            proxy = MCPProxy(port: port, token: "the-token", endpoints: [spec]) { name, header in
                name == "gh" && header == "Authorization" ? "Bearer gh-secret" : nil
            }
        }
        let started = try XCTUnwrap(proxy)
        started.start()
        defer { started.stop() }

        let answered = try curl(["-X", "POST", "-H", "X-Visor-Proxy: the-token", "-H", "X-Visor-Session: s1", "-H", "Content-Type: application/json",
                                 "--data-binary", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, "http://127.0.0.1:\(port)/mcp/gh"])
        XCTAssertEqual(answered.status, "200")
        XCTAssertEqual(answered.body, #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let seen = try XCTUnwrap(endpoint.requests.withLock { $0.first })
        XCTAssertTrue(seen.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        XCTAssertTrue(seen.contains("Authorization: Bearer gh-secret\r\n"))
        XCTAssertTrue(seen.contains("X-Visor-Session: s1\r\n"))
        XCTAssertFalse(seen.contains("the-token"), "the container's token stops at the proxy")
        XCTAssertTrue(seen.contains(#""method":"tools/list""#))

        XCTAssertEqual(try curl(["-X", "POST", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/gh"]).status, "401")
        XCTAssertEqual(try curl(["-X", "POST", "-H", "X-Visor-Proxy: the-token", "--data-binary", "{}", "http://127.0.0.1:\(port)/mcp/other"]).status, "404")
        XCTAssertEqual(endpoint.requests.withLock { $0.count }, 1)
    }
}
