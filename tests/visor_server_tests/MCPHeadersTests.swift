// `visor-agent-host mcp-headers` (MCPHeadersMain), the Sessions container's
// Claude's headersHelper for agent-proxy's MCP pass-through: it asks its
// agent's wrapper, on the wrapper's MCP socket (AGENT_MCP_SOCKET), with one
// `visor/passThroughHeaders` request, and prints the headers the driver
// answered with; a line that isn't its answer is passed over, and a driver's
// refusal, no wrapper, or no socket named, is said, and no headers printed.
// The wrapper is played here: a Unix socket that answers as agent_protocol's
// relays the driver's answer, a line each.

import CVisorPOSIX
import Foundation
import Synchronization
@testable import VisorMCPBridge
import VisorProtocol
import Testing

/// A wrapper's MCP socket that answers the first line it reads with `lines`,
/// keeping what it read.
private final class FakeWrapperSocket: Sendable {
    let path: String
    let heard = Mutex<[String]>([])
    private let listener: Int32

    init?(answering lines: [String]) {
        path = "/tmp/vmh-\(UUID().uuidString.prefix(8)).sock"
        listener = visor_listen_unix(path)
        guard listener >= 0 else { return nil }
        Thread.detachNewThread { [self] in
            let connection = visor_accept(listener)
            guard connection >= 0 else { return }
            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !received.contains(0x0A) {
                let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                received += buffer[0..<count]
            }
            self.heard.withLock { $0.append(String(decoding: received, as: UTF8.self)) }
            let answer = Array(lines.map { $0 + "\n" }.joined().utf8)
            _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            close(connection)
        }
    }

    func stop() {
        visor_shutdown(listener)
        close(listener)
        unlink(path)
    }
}

extension ServerTests {
@Suite struct MCPHeadersTests {
    @Test func theHeadersAreTheDriversAnswerToItsOneRequest() throws {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzIn0.c2ln"
        let wrapper = try #require(FakeWrapperSocket(answering: [
            #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#,
            #"{"jsonrpc":"2.0","id":"visor-pass-through-headers","result":{"headers":{"X-Visor-Proxy":"\#(token)"}}}"#,
        ]))
        defer { wrapper.stop() }
        let headers = try MCPHeadersMain.headers(socket: wrapper.path, within: 5).get()
        #expect(headers == .object(["X-Visor-Proxy": .string(token)]))
        let asked = try #require(parseJSON(wrapper.heard.withLock { $0.first } ?? ""))
        #expect(asked["method"].string == "visor/passThroughHeaders" && asked["id"].string == "visor-pass-through-headers")
        #expect(asked["params"].isNull, "it asks for nothing but the headers")
    }

    @Test func aRefusalNoWrapperOrNoSocketIsSaidWithNoHeaders() throws {
        let refusing = try #require(FakeWrapperSocket(answering: [
            #"{"jsonrpc":"2.0","id":"visor-pass-through-headers","error":{"code":-32601,"message":"This agent has no token for it."}}"#,
        ]))
        defer { refusing.stop() }
        #expect(MCPHeadersMain.headers(socket: refusing.path, within: 5) == .failure(.init(message: "This agent has no token for it.")))
        let silent = try #require(FakeWrapperSocket(answering: []))
        defer { silent.stop() }
        if case .success = MCPHeadersMain.headers(socket: silent.path, within: 5) { Issue.record("a wrapper that answered nothing gave headers") }
        if case .success = MCPHeadersMain.headers(socket: "/tmp/no-wrapper-\(UUID().uuidString.prefix(8)).sock") {
            Issue.record("no wrapper gave headers")
        }
        #expect(MCPHeadersMain.headers(socket: "") == .failure(.init(message:
            "AGENT_MCP_SOCKET isn't set: Claude runs this under its agent's wrapper, in the Sessions container")))
        #expect(MCPHeadersMain.run([:]) == 1)
    }
}
}
