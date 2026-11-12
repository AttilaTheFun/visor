// The wrapper's line to its driver, against a driver played here over
// gRPC on loopback: the wrapper says who it is, then its rows; the driver
// sends a message; the agent's answer comes up the same stream.

import AgentProtocol
import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
import XCTest

/// A driver that greets each wrapper with one message, and keeps what it hears.
final class TestDriver: AgentProtocol_V1_AgentDriver.SimpleServiceProtocol {
    let heard = Mutex<[AgentProtocol_V1_WrapperMessage]>([])

    func connect(request: RPCAsyncSequence<AgentProtocol_V1_WrapperMessage, any Error>,
                 response: RPCWriter<AgentProtocol_V1_DriverMessage>, context: ServerContext) async throws {
        for try await message in request {
            heard.withLock { $0.append(message) }
            if case .hello = message.message {
                try await response.write(.with { $0.send = .with { $0.id = "d1"; $0.text = "hello from the driver" } })
            }
        }
    }

    var answered: Bool {
        heard.withLock { messages in
            messages.contains { message in
                if case .entries(let rows) = message.message { return rows.entries.contains { $0.text == "echo: hello from the driver" } }
                return false
            }
        }
    }
}

final class DriverLinkTests: XCTestCase {
    func testTheWrapperGreetsItsDriverAndTheAgentAnswersItsMessage() async throws {
        let driver = TestDriver()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [driver]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var spec = AgentProtocol_V1_AgentSpec()
            spec.harness = "claude"
            spec.title = "Linked"
            var agent = AgentProtocol_V1_AgentID()
            agent.uuid = "a2"
            agent.dispatcherURL = "http://dispatcher"
            let core = AgentCore(agent: agent, spec: spec, launch: HarnessLaunch(executable: FakeClaude.path, arguments: []))
            try await core.start()
            let link = try XCTUnwrap(DriverLink(url: "http://127.0.0.1:\(port)", core: core, hostName: "test-host"))
            let linking = Task { await link.run() }
            for _ in 0..<200 where !driver.answered { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(driver.answered, "the agent's answer to the driver's message came up the stream")
            let hello = driver.heard.withLock { $0.first }
            guard case .hello(let said) = hello?.message else { return XCTFail("the first message is the hello") }
            XCTAssertEqual(said.agent.uuid, "a2")
            XCTAssertEqual(said.spec.title, "Linked")
            XCTAssertEqual(said.hostName, "test-host")
            XCTAssertEqual(said.protocol, 1)
            await core.stop(grace: .milliseconds(200))
            _ = await core.ended()
            await linking.value
            server.beginGracefulShutdown()
        }
    }

    func testOnlyAPlainHTTPAddressIsADriver() {
        let core = AgentCore(agent: .init(), spec: .init(), launch: HarnessLaunch(executable: "/bin/true", arguments: []))
        XCTAssertNil(DriverLink(url: "https://example.com", core: core, hostName: "h"))
        XCTAssertNil(DriverLink(url: "not a url", core: core, hostName: "h"))
        XCTAssertEqual(DriverLink(url: "http://visor.local:7433", core: core, hostName: "h")?.port, 7433)
    }
}
