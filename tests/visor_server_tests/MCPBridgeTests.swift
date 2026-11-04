// Visor's MCP server in Swift (`visor-agent-host mcp`), as the Node script
// answered agents: its tools and their calls, `approve` and the ways it
// ends, the passed-on tools, and the WebSocket it reaches the server on —
// its frames, its URL, and a real call to a real server.

import Foundation
import Synchronization
@testable import VisorMCPBridge
import VisorProtocol
@testable import VisorServer
import XCTest

/// What the bridge said to the agent, in order.
private final class Said: MCPOutput {
    private let lines = Mutex<[JSONValue]>([])

    func send(_ message: JSONValue) { lines.withLock { $0.append(message) } }

    var all: [JSONValue] { lines.withLock { $0 } }

    /// The first message that answers `id`, once it has come.
    func answer(_ id: Int, within seconds: Double = 5) async -> JSONValue? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = all.first(where: { $0["id"] == .number(Double(id)) }) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

/// A server that answers each mode as told, and remembers what it was asked.
private final class FakeServer: MCPServerLink {
    struct State {
        var calls: [[String: JSONValue]] = []
        var asks: [[String: JSONValue]] = []
        var replies: [String: MCPReply] = [:]
        /// The answer to `approve`; nil: wait until given up.
        var answer: MCPAnswer?
    }

    let state = Mutex(State())

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        state.withLock { state in
            state.calls.append(fields)
            return state.replies[fields["mode"]?.string ?? ""] ?? MCPReply(ok: true, text: "")
        }
    }

    func ask(_ request: [String: JSONValue], _ asking: MCPAsking) async -> MCPAnswer {
        let answer = state.withLock { state in
            state.asks.append(request)
            return state.answer
        }
        if let answer { return answer }
        while asking.reason == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return MCPAnswer(allow: false, answers: nil, reason: asking.reason)
    }
}

final class MCPBridgeTests: ServerTestCase {
    private func bridge(approvals: Bool = false, contained: Bool = false, server: FakeServer = FakeServer(),
                        timing: MCPTiming = MCPTiming()) -> (MCPBridge, FakeServer, Said) {
        let said = Said()
        return (MCPBridge(link: server, output: said, approvals: approvals, contained: contained, timing: timing), server, said)
    }

    private func call(_ id: Int, _ name: String, _ arguments: String = "{}", meta: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)\#(meta)}}"#
    }

    private func text(_ answer: JSONValue?) -> String? { answer?["result"]["content"][0]["text"].string }

    func testInitializeSaysWhereTheAgentRuns() async {
        let (here, _, said) = self.bridge()
        await here.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let answer = await said.answer(1)
        XCTAssertEqual(answer?["result"]["protocolVersion"].string, "2025-06-18")
        XCTAssertEqual(answer?["result"]["capabilities"]["tools"]["listChanged"].bool, true)
        XCTAssertEqual(answer?["result"]["serverInfo"]["name"].string, "visor")
        XCTAssertFalse(answer?["result"]["instructions"].string?.contains("Linux container") ?? true)

        let (inside, _, insideSaid) = self.bridge(contained: true)
        await inside.handle(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        let contained = await insideSaid.answer(2)
        XCTAssertEqual(contained?["result"]["protocolVersion"].string, "2024-11-05", "the protocol's own when the agent says none")
        XCTAssertTrue(contained?["result"]["instructions"].string?.contains("You run in a Linux container") ?? false)
    }

    func testTheToolsListedWithTheirOwnAndThePassedOn() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"github__search","description":"Search"}]"#) }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let names = await said.answer(3)?["result"]["tools"].array?.compactMap { $0["name"].string }
        XCTAssertEqual(names, ["approve", "list_sessions", "send_message", "read_messages", "message_status", "github__search"])

        let (plain, _, plainSaid) = self.bridge()
        await plain.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let plainNames = await plainSaid.answer(4)?["result"]["tools"].array?.compactMap { $0["name"].string }
        XCTAssertEqual(plainNames, ["list_sessions", "send_message", "read_messages", "message_status"], "no approve unless asked for")
    }

    func testASessionToolGoesToTheServerUnderTheNamesAnAgentReachesFor() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["send"] = MCPReply(ok: true, text: "Sent.") }
        let (bridge, _, said) = self.bridge(server: server)
        await bridge.handle(call(5, "send_message", #"{"session_id":"B","server_id":"S1","message":"Is the API done?"}"#))
        let answer = await said.answer(5)
        XCTAssertEqual(text(answer), "Sent.")
        XCTAssertEqual(answer?["result"]["isError"].bool, false)
        let fields = server.state.withLock { $0.calls.last }
        XCTAssertEqual(fields?["mode"], .string("send"))
        XCTAssertEqual(fields?["session"], .string("B"))
        XCTAssertEqual(fields?["server"], .string("S1"))
        XCTAssertEqual(fields?["text"], .string("Is the API done?"))

        await bridge.handle(call(6, "read_messages", #"{"session":"B","server":"S1","count":"7.5"}"#))
        _ = await said.answer(6)
        XCTAssertEqual(server.state.withLock { $0.calls.last?["rows"] }, .number(8), "a count rounded as JavaScript's Math.round")
    }

    func testASessionLeftOutIsSaidPlainly() async {
        let (bridge, server, said) = self.bridge()
        await bridge.handle(call(7, "send_message", #"{"text":"hi"}"#))
        let answer = await said.answer(7)
        XCTAssertEqual(answer?["result"]["isError"].bool, true)
        XCTAssertTrue(text(answer)?.hasPrefix("send_message needs `session` and `server`") ?? false)
        XCTAssertTrue(server.state.withLock { $0.calls.isEmpty }, "nothing asked of the server")

        await bridge.handle(call(8, "make_coffee"))
        let unknown = await said.answer(8)
        XCTAssertEqual(text(unknown), "No tool make_coffee")
        XCTAssertEqual(unknown?["result"]["isError"].bool, true)
    }

    func testAPassedOnToolIsPassedOnAndItsResultComesBackAsItWas() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_call"] = MCPReply(ok: true, text: #"{"content":[{"type":"text","text":"3 results"}],"structured":{"n":3}}"#) }
        let (bridge, _, said) = self.bridge(server: server)
        await bridge.handle(call(9, "github__search", #"{"q":"visor"}"#))
        let answer = await said.answer(9)
        XCTAssertEqual(text(answer), "3 results")
        XCTAssertEqual(answer?["result"]["structured"]["n"], .number(3))
        let asked = server.state.withLock { $0.calls.last }
        XCTAssertEqual(asked?["mode"], .string("mcp_call"))
        let request = parseJSON(asked?["text"]?.string ?? "")
        XCTAssertEqual(request?["tool"], .string("github__search"))
        XCTAssertEqual(request?["arguments"]["q"], .string("visor"))

        server.state.withLock { $0.replies["mcp_call"] = MCPReply(ok: false, text: "The endpoint is down.") }
        await bridge.handle(call(10, "github__search"))
        let failed = await said.answer(10)
        XCTAssertEqual(failed?["result"]["isError"].bool, true)
        XCTAssertEqual(text(failed), "The endpoint is down.")
    }

    func testApproveAllowedTakesAQuestionsAnswersIntoTheToolsInput() async {
        let server = FakeServer()
        server.state.withLock { $0.answer = MCPAnswer(allow: true, answers: .object(["Which?": .string("Blue")]), reason: nil) }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(call(11, "approve", #"{"tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which?"}]}}"#))
        let decision = parseJSON(text(await said.answer(11)) ?? "")
        XCTAssertEqual(decision?["behavior"], .string("allow"))
        XCTAssertEqual(decision?["updatedInput"]["answers"]["Which?"], .string("Blue"))
        XCTAssertEqual(decision?["updatedInput"]["questions"][0]["question"], .string("Which?"))
        let asked = server.state.withLock { $0.asks.last }
        XCTAssertEqual(asked?["text"], .string("AskUserQuestion"))
        XCTAssertEqual(asked?["prompt"], .string("Which?"))
        XCTAssertEqual(asked?["questions"]?[0]["question"], .string("Which?"))
    }

    func testApproveDeniedSaysWhy() async {
        let server = FakeServer()
        server.state.withLock { $0.answer = .no }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(call(12, "approve", #"{"tool_name":"Bash","input":{"command":"rm -rf build\necho done"}}"#))
        let decision = parseJSON(text(await said.answer(12)) ?? "")
        XCTAssertEqual(decision?["behavior"], .string("deny"))
        XCTAssertEqual(decision?["message"], .string("The user denied this from Visor."))
        XCTAssertEqual(server.state.withLock { $0.asks.last?["prompt"] }, .string("rm -rf build"), "the command's first line")
    }

    func testApproveWithNoProgressIsAnsweredNotYetBeforeTheAgentGivesUp() async {
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .milliseconds(100), watch: .seconds(30))
        let (bridge, _, said) = self.bridge(approvals: true, timing: timing)
        await bridge.handle(call(13, "approve", #"{"tool_name":"Bash","input":{"command":"make"}}"#))
        let decision = parseJSON(text(await said.answer(13)) ?? "")
        XCTAssertEqual(decision?["behavior"], .string("deny"))
        XCTAssertTrue(decision?["message"].string?.hasPrefix("The person has not answered in Visor for 25 minutes") ?? false)
    }

    func testApproveSaysItIsStillWaitingAndIsLetGoOfWhenTheAgentGivesUp() async {
        let timing = MCPTiming(heartbeat: .milliseconds(30), unanswered: .seconds(60), watch: .seconds(30))
        let (bridge, server, said) = self.bridge(approvals: true, timing: timing)
        await bridge.handle(call(14, "approve", #"{"tool_name":"Bash","input":{"command":"make"}}"#, meta: #","_meta":{"progressToken":"p14"}"#))
        let deadline = Date().addingTimeInterval(5)
        while said.all.filter({ $0["method"].string == "notifications/progress" }).count < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let beats = said.all.filter { $0["method"].string == "notifications/progress" }
        XCTAssertGreaterThanOrEqual(beats.count, 2)
        XCTAssertEqual(beats.first?["params"]["progressToken"], .string("p14"))
        XCTAssertEqual(beats.first?["params"]["progress"], .number(1))

        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":14}}"#)
        try? await Task.sleep(for: .milliseconds(200))
        let late = await said.answer(14, within: 0.2)
        XCTAssertNil(late, "nothing answered for a call the agent gave up on")
        XCTAssertEqual(server.state.withLock { $0.asks.count }, 1)
        let quiet = said.all.count
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(said.all.count, quiet, "no more progress once it's let go of")
    }

    func testThePassedOnToolsAreLookedAtAgainAndTheAgentToldWhenTheyChange() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"a__one"}]"#) }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(30))
        let (bridge, _, said) = self.bridge(server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":15,"method":"tools/list"}"#)
        _ = await said.answer(15)
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(said.all.contains { $0["method"].string == "notifications/tools/list_changed" }, "nothing changed")

        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"a__one"},{"name":"a__two"}]"#) }
        let deadline = Date().addingTimeInterval(5)
        while !said.all.contains(where: { $0["method"].string == "notifications/tools/list_changed" }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(said.all.filter { $0["method"].string == "notifications/tools/list_changed" }.count, 1)
    }

    func testPingAndAnUnknownMethod() async {
        let (bridge, _, said) = self.bridge()
        await bridge.handle(#"{"jsonrpc":"2.0","id":16,"method":"ping"}"#)
        let pong = await said.answer(16)
        XCTAssertEqual(pong?["result"], .object([:]))
        await bridge.handle(#"{"jsonrpc":"2.0","id":17,"method":"resources/list"}"#)
        let unknown = await said.answer(17)
        XCTAssertEqual(unknown?["error"]["code"], .number(-32601))
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        await bridge.handle("not json")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(said.all.count, 2, "a notification and a line that isn't JSON go unanswered")
    }

    // MARK: The wire

    func testTheURL() {
        XCTAssertEqual(MCPURL("ws://127.0.0.1:7433"), MCPURL("ws://127.0.0.1:7433/"))
        let url = MCPURL("ws://192.168.64.1:7440/socket")
        XCTAssertEqual(url?.host, "192.168.64.1")
        XCTAssertEqual(url?.port, 7440)
        XCTAssertEqual(url?.path, "/socket")
        XCTAssertEqual(MCPURL("ws://[::1]:7433")?.host, "::1")
        XCTAssertEqual(MCPURL("ws://[::1]:7433")?.hostHeader, "[::1]:7433")
        XCTAssertEqual(MCPURL("ws://mini.local")?.port, 80)
        XCTAssertNil(MCPURL("wss://example.com"))
        XCTAssertNil(MCPURL("ws://host:notaport"))
        XCTAssertNil(MCPURL("ws://:7433"))
    }

    func testFramesOutMaskedAndInWhole() {
        let mask: [UInt8] = [1, 2, 3, 4]
        let small = MCPWebSocketFrames.frame(0x1, Array("hi".utf8), mask: mask)
        XCTAssertEqual(small, [0x81, 0x82, 1, 2, 3, 4, UInt8(ascii: "h") ^ 1, UInt8(ascii: "i") ^ 2])
        XCTAssertEqual(MCPWebSocketFrames.read(small), .frame(.init(final: true, opcode: 0x1, payload: Array("hi".utf8)), small.count),
                       "a masked frame read back")
        let medium = MCPWebSocketFrames.frame(0x1, [UInt8](repeating: 7, count: 300), mask: mask)
        XCTAssertEqual(Array(medium.prefix(4)), [0x81, 0x80 | 126, 0x01, 0x2C])
        let large = MCPWebSocketFrames.frame(0x1, [UInt8](repeating: 7, count: 70_000), mask: mask)
        XCTAssertEqual(large[1], 0x80 | 127)
        XCTAssertEqual(large.count, 14 + 70_000)

        // The server's: unmasked, a 16-bit length, split across reads.
        let server: [UInt8] = [0x81, 126, 0x01, 0x2C] + [UInt8](repeating: 65, count: 300)
        XCTAssertEqual(MCPWebSocketFrames.read(Array(server.prefix(3))), .incomplete)
        XCTAssertEqual(MCPWebSocketFrames.read(Array(server.prefix(100))), .incomplete)
        guard case .frame(let frame, let taken) = MCPWebSocketFrames.read(server + [0x89, 0]) else { return XCTFail("a whole frame") }
        XCTAssertEqual(taken, server.count)
        XCTAssertEqual(frame.payload.count, 300)
        XCTAssertEqual(MCPWebSocketFrames.read([0x81, 127, 0xFF, 0, 0, 0, 0, 0, 0, 0]), .invalid, "larger than any message")
    }

    /// A real call, on a real WebSocket, to a real server: the sessions
    /// listed to an agent with the server's token; refused without it.
    @MainActor
    func testACallReachesARealServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-mcp-\(ProcessInfo.processInfo.processIdentifier).sock"
        defer { VisorServer.socketPathOverride = nil }
        let port = ServerTestCase.freePort()
        let server = VisorServer(port: port)
        defer { server.stop() }
        server.password = "pearl-grove"
        for _ in 0..<60 where !server.listening { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(server.listening)
        // The agent asking is one of the server's sessions, as any is.
        server.sessions = [("A", "Server work"), ("B", "Client work")].map { id, title in
            SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0),
                          process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        }

        let link = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: server.agentToken, session: "A")
        let reply = await link.call(["mode": .string("sessions")])
        XCTAssertTrue(reply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("B — Client work"), reply.text)

        let stranger = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: "not-the-token", session: "A")
        let refused = await stranger.call(["mode": .string("sessions")])
        XCTAssertFalse(refused.ok)

        let nobody = MCPWebSocketLink(url: "ws://127.0.0.1:\(ServerTestCase.freePort())", token: "", session: "A")
        let unreachable = await nobody.call(["mode": .string("sessions")])
        XCTAssertEqual(unreachable, MCPReply(ok: false, text: "Visor is not reachable."))
    }
}
