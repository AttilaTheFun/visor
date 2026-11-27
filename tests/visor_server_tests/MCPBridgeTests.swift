// Visor's MCP server in Swift (`visor-agent-host mcp`), as the Node script
// answered agents: its tools and their calls, `approve` and the ways it
// ends, the passed-on tools, and the WebSocket it reaches the server on —
// its frames, its URL, and a real call to a real server.

import Foundation
import Synchronization
@testable import VisorAgent
@testable import VisorMCPBridge
import VisorProtocol
@testable import VisorServer
import Testing

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
        /// How long each call takes to be answered (a server that is slow).
        var delay: Duration = .zero
    }

    let state = Mutex(State())

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        let (reply, delay) = state.withLock { state in
            state.calls.append(fields)
            return (state.replies[fields["mode"]?.string ?? ""] ?? MCPReply(ok: true, text: ""), state.delay)
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return reply
    }

    /// How many times the passed-on tools were asked for.
    var looks: Int { state.withLock { $0.calls.filter { $0["mode"]?.string == "mcp_tools" }.count } }

    /// Until `count` more looks have begun (or 10 s).
    func waitForLooks(_ count: Int) async {
        let target = looks + count
        let deadline = Date().addingTimeInterval(10)
        while looks < target, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
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

extension ServerTests {
@Suite @MainActor final class MCPBridgeTests {
    init() { TestPlatform.install() }

    private func bridge(approvals: Bool = false, contained: Bool = false, passesOn: Bool = true, server: FakeServer = FakeServer(),
                        timing: MCPTiming = MCPTiming()) -> (MCPBridge, FakeServer, Said) {
        let said = Said()
        return (MCPBridge(link: server, output: said, approvals: approvals, contained: contained, passesOn: passesOn, timing: timing),
                server, said)
    }

    private func call(_ id: Int, _ name: String, _ arguments: String = "{}", meta: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)\#(meta)}}"#
    }

    private func text(_ answer: JSONValue?) -> String? { answer?["result"]["content"][0]["text"].string }

    private func names(_ answer: JSONValue?) -> [String]? { answer?["result"]["tools"].array?.compactMap { $0["name"].string } }

    /// How many times the agent was told the tools changed.
    private func changes(_ said: Said) -> Int { said.all.filter { $0["method"].string == "notifications/tools/list_changed" }.count }

    /// Until the agent has been told the tools changed `count` times (or 5 s).
    private func waitForChanges(_ said: Said, _ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while changes(said) < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static let own = ["list_sessions", "send_message", "read_messages", "message_status", "read_inbox", "read_outbox"]

    /// Passed-on tools as an endpoint gives them: schemas with many keys,
    /// which a parse puts in no set order.
    private static func passedOn(_ names: [String]) -> String {
        let properties = (0..<16).map { #""field\#($0)":{"type":"string","description":"Field \#($0)."}"# }.joined(separator: ",")
        let tools = names.map { name in
            #"{"name":"\#(name)","description":"\#(name), passed on.","inputSchema":{"type":"object","properties":{\#(properties)},"required":["field0","field1"]}}"#
        }
        return "[" + tools.joined(separator: ",") + "]"
    }

    @Test func testInitializeSaysWhereTheAgentRuns() async {
        let (here, _, said) = self.bridge()
        await here.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let answer = await said.answer(1)
        #expect((answer?["result"]["protocolVersion"].string) == "2025-06-18")
        #expect((answer?["result"]["capabilities"]["tools"]["listChanged"].bool) == true)
        #expect((answer?["result"]["serverInfo"]["name"].string) == "visor")
        #expect(!(answer?["result"]["instructions"].string?.contains("Linux container") ?? true))

        let (inside, _, insideSaid) = self.bridge(contained: true)
        await inside.handle(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        let contained = await insideSaid.answer(2)
        #expect((contained?["result"]["protocolVersion"].string) == "2024-11-05", "the protocol's own when the agent says none")
        #expect(contained?["result"]["instructions"].string?.contains("You run in a Linux container") ?? false)
        #expect(!(answer?["result"]["instructions"].string?.contains("aren't passed on") ?? true))

        // A runner's container agent, with none of the passed-on servers:
        // told its own tools are still here (pilot 4, 18 Nov).
        let (runner, _, runnerSaid) = self.bridge(passesOn: false)
        await runner.handle(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#)
        let told = await runnerSaid.answer(3)?["result"]["instructions"].string ?? ""
        #expect(told.contains("send_message") && told.contains("aren't passed on"))
    }

    @Test func testTheToolsListedWithTheirOwnAndThePassedOn() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"github__search","description":"Search"}]"#) }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let names = await said.answer(3)?["result"]["tools"].array?.compactMap { $0["name"].string }
        #expect(names == ["approve", "list_sessions", "send_message", "read_messages", "message_status", "read_inbox", "read_outbox",
                               "github__search"])

        let (plain, _, plainSaid) = self.bridge()
        await plain.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let plainNames = await plainSaid.answer(4)?["result"]["tools"].array?.compactMap { $0["name"].string }
        #expect(plainNames == ["list_sessions", "send_message", "read_messages", "message_status", "read_inbox", "read_outbox"], "no approve unless asked for")
    }

    /// An agent on a runner (VisorDriver's DrivenMCP): Visor's own tools
    /// only. The computer's passed-on ones aren't asked for, listed, looked
    /// at again or called, whatever the server would say.
    @Test func testAnAgentOnARunnerGetsOnlyVisorsOwnTools() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"gh__pr_create","description":"Opens a pull request."}]"#) }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(30))
        let (bridge, _, said) = self.bridge(passesOn: false, server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":30,"method":"tools/list"}"#)
        let names = await said.answer(30)?["result"]["tools"].array?.compactMap { $0["name"].string }
        #expect(names == ["list_sessions", "send_message", "read_messages", "message_status", "read_inbox", "read_outbox"])

        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await bridge.handle(call(31, "gh__pr_create", #"{"title":"Sub-sessions"}"#))
        let refused = await said.answer(31)
        #expect((refused?["result"]["isError"].bool) == true)
        #expect(text(refused)?.contains("isn't one of Visor's tools") ?? false, Comment(rawValue: text(refused) ?? ""))
        try? await Task.sleep(for: .milliseconds(150))
        let modes = server.state.withLock { $0.calls.compactMap { $0["mode"]?.string } }
        #expect(!modes.contains("mcp_tools") && !modes.contains("mcp_call"), "never asked of the server: \(modes)")
        #expect(!(said.all.contains { $0["method"].string == "notifications/tools/list_changed" }), "nothing watched")
        await bridge.close()
    }

    @Test func testASessionToolGoesToTheServerUnderTheNamesAnAgentReachesFor() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["send"] = MCPReply(ok: true, text: "Sent.") }
        let (bridge, _, said) = self.bridge(server: server)
        await bridge.handle(call(5, "send_message", #"{"session_id":"B","server_id":"S1","message":"Is the API done?"}"#))
        let answer = await said.answer(5)
        #expect(text(answer) == "Sent.")
        #expect((answer?["result"]["isError"].bool) == false)
        let fields = server.state.withLock { $0.calls.last }
        #expect((fields?["mode"]) == .string("send"))
        #expect((fields?["session"]) == .string("B"))
        #expect((fields?["server"]) == .string("S1"))
        #expect((fields?["text"]) == .string("Is the API done?"))

        await bridge.handle(call(6, "read_messages", #"{"session":"B","server":"S1","count":"7.5"}"#))
        _ = await said.answer(6)
        #expect((server.state.withLock { $0.calls.last?["rows"] }) == .number(8), "a count rounded as JavaScript's Math.round")
    }

    @Test func testASessionLeftOutIsSaidPlainly() async {
        let (bridge, server, said) = self.bridge()
        await bridge.handle(call(7, "send_message", #"{"text":"hi"}"#))
        let answer = await said.answer(7)
        #expect((answer?["result"]["isError"].bool) == true)
        #expect(text(answer)?.hasPrefix("send_message needs `session` and `server`") ?? false)
        #expect(server.state.withLock { $0.calls.isEmpty }, "nothing asked of the server")

        await bridge.handle(call(8, "make_coffee"))
        let unknown = await said.answer(8)
        #expect(text(unknown) == "No tool make_coffee")
        #expect((unknown?["result"]["isError"].bool) == true)
    }

    @Test func testAPassedOnToolIsPassedOnAndItsResultComesBackAsItWas() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_call"] = MCPReply(ok: true, text: #"{"content":[{"type":"text","text":"3 results"}],"structured":{"n":3}}"#) }
        let (bridge, _, said) = self.bridge(server: server)
        await bridge.handle(call(9, "github__search", #"{"q":"visor"}"#))
        let answer = await said.answer(9)
        #expect(text(answer) == "3 results")
        #expect((answer?["result"]["structured"]["n"]) == .number(3))
        let asked = server.state.withLock { $0.calls.last }
        #expect((asked?["mode"]) == .string("mcp_call"))
        let request = parseJSON(asked?["text"]?.string ?? "")
        #expect((request?["tool"]) == .string("github__search"))
        #expect((request?["arguments"]["q"]) == .string("visor"))

        server.state.withLock { $0.replies["mcp_call"] = MCPReply(ok: false, text: "The endpoint is down.") }
        await bridge.handle(call(10, "github__search"))
        let failed = await said.answer(10)
        #expect((failed?["result"]["isError"].bool) == true)
        #expect(text(failed) == "The endpoint is down.")
    }

    @Test func testApproveAllowedTakesAQuestionsAnswersIntoTheToolsInput() async {
        let server = FakeServer()
        server.state.withLock { $0.answer = MCPAnswer(allow: true, answers: .object(["Which?": .string("Blue")]), reason: nil) }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(call(11, "approve", #"{"tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which?"}]}}"#))
        let decision = parseJSON(text(await said.answer(11)) ?? "")
        #expect((decision?["behavior"]) == .string("allow"))
        #expect((decision?["updatedInput"]["answers"]["Which?"]) == .string("Blue"))
        #expect((decision?["updatedInput"]["questions"][0]["question"]) == .string("Which?"))
        let asked = server.state.withLock { $0.asks.last }
        #expect((asked?["text"]) == .string("AskUserQuestion"))
        #expect((asked?["prompt"]) == .string("Which?"))
        #expect((asked?["questions"]?[0]["question"]) == .string("Which?"))
    }

    @Test func testApproveDeniedSaysWhy() async {
        let server = FakeServer()
        server.state.withLock { $0.answer = .no }
        let (bridge, _, said) = self.bridge(approvals: true, server: server)
        await bridge.handle(call(12, "approve", #"{"tool_name":"Bash","input":{"command":"rm -rf build\necho done"}}"#))
        let decision = parseJSON(text(await said.answer(12)) ?? "")
        #expect((decision?["behavior"]) == .string("deny"))
        #expect((decision?["message"]) == .string("The user denied this from Visor."))
        #expect((server.state.withLock { $0.asks.last?["prompt"] }) == .string("rm -rf build"), "the command's first line")
    }

    @Test func testApproveWithNoProgressIsAnsweredNotYetBeforeTheAgentGivesUp() async {
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .milliseconds(100), watch: .seconds(30))
        let (bridge, _, said) = self.bridge(approvals: true, timing: timing)
        await bridge.handle(call(13, "approve", #"{"tool_name":"Bash","input":{"command":"make"}}"#))
        let decision = parseJSON(text(await said.answer(13)) ?? "")
        #expect((decision?["behavior"]) == .string("deny"))
        #expect(decision?["message"].string?.hasPrefix("The person has not answered in Visor for 25 minutes") ?? false)
    }

    @Test func testApproveSaysItIsStillWaitingAndIsLetGoOfWhenTheAgentGivesUp() async {
        let timing = MCPTiming(heartbeat: .milliseconds(30), unanswered: .seconds(60), watch: .seconds(30))
        let (bridge, server, said) = self.bridge(approvals: true, timing: timing)
        await bridge.handle(call(14, "approve", #"{"tool_name":"Bash","input":{"command":"make"}}"#, meta: #","_meta":{"progressToken":"p14"}"#))
        let deadline = Date().addingTimeInterval(5)
        while said.all.filter({ $0["method"].string == "notifications/progress" }).count < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let beats = said.all.filter { $0["method"].string == "notifications/progress" }
        #expect(beats.count >= 2)
        #expect((beats.first?["params"]["progressToken"]) == .string("p14"))
        #expect((beats.first?["params"]["progress"]) == .number(1))

        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":14}}"#)
        try? await Task.sleep(for: .milliseconds(200))
        let late = await said.answer(14, within: 0.2)
        #expect(late == nil, "nothing answered for a call the agent gave up on")
        #expect((server.state.withLock { $0.asks.count }) == 1)
        let quiet = said.all.count
        try? await Task.sleep(for: .milliseconds(120))
        #expect(said.all.count == quiet, "no more progress once it's let go of")
    }

    @Test func testThePassedOnToolsAreLookedAtAgainAndTheAgentToldWhenTheyChange() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"a__one"}]"#) }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(30))
        let (bridge, _, said) = self.bridge(server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":15,"method":"tools/list"}"#)
        _ = await said.answer(15)
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!(said.all.contains { $0["method"].string == "notifications/tools/list_changed" }), "nothing changed")

        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: #"[{"name":"a__one"},{"name":"a__two"}]"#) }
        let deadline = Date().addingTimeInterval(5)
        while !said.all.contains(where: { $0["method"].string == "notifications/tools/list_changed" }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect((said.all.filter { $0["method"].string == "notifications/tools/list_changed" }.count) == 1)
    }

    /// No word to the agent in many looks when nothing changed: the tools
    /// are held against what it was given as values, an object's keys in
    /// any order (0.64 compared their JSON as text, and since a parse puts
    /// a schema's keys in no set order it told the agent on every look,
    /// every 30 s, for days).
    @Test func testNoListChangedInManyLooksWhileNothingChanges() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: Self.passedOn(["gh__pr_create", "oss__lease", "shireworks__exec"])) }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(10))
        let (bridge, _, said) = self.bridge(server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":40,"method":"tools/list"}"#)
        #expect(names(await said.answer(40)) == Self.own + ["gh__pr_create", "oss__lease", "shireworks__exec"])
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.waitForLooks(40)
        #expect(server.looks >= 41)
        #expect(changes(said) == 0, "nothing changed in \(server.looks - 1) looks")

        let one = parseJSON(#"{"name":"a","inputSchema":{"type":"object","required":["x"],"properties":{"x":{"type":"string"}}}}"#)!
        let other = parseJSON(#"{"inputSchema":{"properties":{"x":{"type":"string"}},"required":["x"],"type":"object"},"name":"a"}"#)!
        #expect(MCPBridge.signature([one]) == MCPBridge.signature([other]), "the same tool, its keys in another order")
        let changed = parseJSON(#"{"name":"a","inputSchema":{"type":"object","required":["y"]}}"#)!
        #expect(MCPBridge.signature([one]) != MCPBridge.signature([changed]))
        await bridge.close()
    }

    /// The server not answering (restarting) or slow: the list answers at
    /// once with Visor's own tools and the last good passed-on ones, and
    /// the agent isn't told anything changed; when the tools really change
    /// (an endpoint left out, then back), it is told once each time.
    @Test func testTheLastGoodToolsStayWhileTheServerDoesntAnswer() async {
        let server = FakeServer()
        let both = Self.passedOn(["gh__pr_create", "oss__lease"])
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: both) }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(20), look: .milliseconds(200),
                               retry: .milliseconds(5))
        let (bridge, _, said) = self.bridge(server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":50,"method":"tools/list"}"#)
        #expect(names(await said.answer(50)) == Self.own + ["gh__pr_create", "oss__lease"])
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        // Down: every look refused.
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: false, text: "Visor is not reachable.") }
        await server.waitForLooks(10)
        await bridge.handle(#"{"jsonrpc":"2.0","id":51,"method":"tools/list"}"#)
        #expect(names(await said.answer(51, within: 0.1)) == Self.own + ["gh__pr_create", "oss__lease"], "at once, the last good list")

        // Slow: answering after the look's limit.
        server.state.withLock { state in
            state.replies["mcp_tools"] = MCPReply(ok: true, text: "[]")
            state.delay = .seconds(1)
        }
        await server.waitForLooks(3)
        await bridge.handle(#"{"jsonrpc":"2.0","id":52,"method":"tools/list"}"#)
        #expect(names(await said.answer(52, within: 0.1)) == Self.own + ["gh__pr_create", "oss__lease"], "a slow server's answer isn't waited on")

        // Back, as it was.
        server.state.withLock { state in
            state.replies["mcp_tools"] = MCPReply(ok: true, text: both)
            state.delay = .zero
        }
        try? await Task.sleep(for: .milliseconds(1100))
        await server.waitForLooks(5)
        #expect(changes(said) == 0, "down, slow and back as it was: nothing changed")

        // A real change: oss's tools left out (the server's, once it has
        // been gone long enough), and back.
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: Self.passedOn(["gh__pr_create"])) }
        await waitForChanges(said, 1)
        await server.waitForLooks(5)
        #expect(changes(said) == 1)
        await bridge.handle(#"{"jsonrpc":"2.0","id":53,"method":"tools/list"}"#)
        #expect(names(await said.answer(53)) == Self.own + ["gh__pr_create"])
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: both) }
        await waitForChanges(said, 2)
        await server.waitForLooks(5)
        #expect(changes(said) == 2)
        await bridge.close()
    }

    /// A first list the server doesn't answer: Visor's own tools, and the
    /// agent told once the passed-on ones come.
    @Test func testTheFirstListWithoutTheServerIsVisorsOwn() async {
        let server = FakeServer()
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: false, text: "Visor is not reachable.") }
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(20), look: .milliseconds(200),
                               retry: .milliseconds(5))
        let (bridge, _, said) = self.bridge(server: server, timing: timing)
        await bridge.handle(#"{"jsonrpc":"2.0","id":60,"method":"tools/list"}"#)
        #expect(names(await said.answer(60)) == Self.own)
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.waitForLooks(3)
        #expect(changes(said) == 0)
        server.state.withLock { $0.replies["mcp_tools"] = MCPReply(ok: true, text: Self.passedOn(["gh__pr_create"])) }
        await waitForChanges(said, 1)
        await server.waitForLooks(5)
        #expect(changes(said) == 1)
        await bridge.handle(#"{"jsonrpc":"2.0","id":61,"method":"tools/list"}"#)
        #expect(names(await said.answer(61)) == Self.own + ["gh__pr_create"])
        await bridge.close()
    }

    /// A look the server answers in time is its answer, every time: the
    /// limit's timer, cancelled once the answer has come, gives nothing.
    /// (It gave nil, which now and then came first: a list without the
    /// passed-on tools the server had sent.)
    @Test func testAnAnswerInTimeIsNeverTakenForNone() async {
        var dropped = 0
        for _ in 0..<2000 {
            let answer = await MCPDeadline.first(within: .seconds(60)) { 1 }
            if answer == nil { dropped += 1 }
        }
        #expect(dropped == 0, "\(dropped) of 2000 answers in time taken for none")
    }

    @Test func testPingAndAnUnknownMethod() async {
        let (bridge, _, said) = self.bridge()
        await bridge.handle(#"{"jsonrpc":"2.0","id":16,"method":"ping"}"#)
        let pong = await said.answer(16)
        #expect((pong?["result"]) == .object([:]))
        await bridge.handle(#"{"jsonrpc":"2.0","id":17,"method":"resources/list"}"#)
        let unknown = await said.answer(17)
        #expect((unknown?["error"]["code"]) == .number(-32601))
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        await bridge.handle("not json")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(said.all.count == 2, "a notification and a line that isn't JSON go unanswered")
    }

    // MARK: The wire

    @Test func testTheURL() {
        #expect(MCPURL("ws://127.0.0.1:7433") == MCPURL("ws://127.0.0.1:7433/"))
        let url = MCPURL("ws://192.168.64.1:7440/socket")
        #expect((url?.host) == "192.168.64.1")
        #expect((url?.port) == 7440)
        #expect((url?.path) == "/socket")
        #expect((MCPURL("ws://[::1]:7433")?.host) == "::1")
        #expect((MCPURL("ws://[::1]:7433")?.hostHeader) == "[::1]:7433")
        #expect((MCPURL("ws://mini.local")?.port) == 80)
        #expect(MCPURL("wss://example.com") == nil)
        #expect(MCPURL("ws://host:notaport") == nil)
        #expect(MCPURL("ws://:7433") == nil)
    }

    @Test func testFramesOutMaskedAndInWhole() {
        let mask: [UInt8] = [1, 2, 3, 4]
        let small = MCPWebSocketFrames.frame(0x1, Array("hi".utf8), mask: mask)
        #expect(small == [0x81, 0x82, 1, 2, 3, 4, UInt8(ascii: "h") ^ 1, UInt8(ascii: "i") ^ 2])
        #expect(MCPWebSocketFrames.read(small) == (.frame(.init(final: true, opcode: 0x1, payload: Array("hi".utf8)), small.count)), "a masked frame read back")
        let medium = MCPWebSocketFrames.frame(0x1, [UInt8](repeating: 7, count: 300), mask: mask)
        #expect((Array(medium.prefix(4))) == [0x81, 0x80 | 126, 0x01, 0x2C])
        let large = MCPWebSocketFrames.frame(0x1, [UInt8](repeating: 7, count: 70_000), mask: mask)
        #expect((large[1]) == (0x80 | 127))
        #expect(large.count == (14 + 70_000))

        // The server's: unmasked, a 16-bit length, split across reads.
        let server: [UInt8] = [0x81, 126, 0x01, 0x2C] + [UInt8](repeating: 65, count: 300)
        #expect((MCPWebSocketFrames.read(Array(server.prefix(3)))) == .incomplete)
        #expect((MCPWebSocketFrames.read(Array(server.prefix(100)))) == .incomplete)
        guard case .frame(let frame, let taken) = MCPWebSocketFrames.read(server + [0x89, 0]) else { Issue.record("a whole frame"); return }
        #expect(taken == server.count)
        #expect(frame.payload.count == 300)
        #expect(MCPWebSocketFrames.read([0x81, 127, 0xFF, 0, 0, 0, 0, 0, 0, 0]) == .invalid, "larger than any message")
    }

    /// Claude's MCP config no longer carries VISOR_PORT, VISOR_SESSION and
    /// VISOR_TOKEN (visor#423): Claude Code passes them on from the agent's
    /// environment. Without them, every request is refused with why.
    @Test func testAMissingEnvironmentIsSaidToEveryRequest() {
        let given = ["VISOR_PORT": "7433", "VISOR_SESSION": "A", "VISOR_TOKEN": "t"]
        #expect(MCPMissingEnvironment(given) == nil)
        #expect(MCPMissingEnvironment(given.merging(["VISOR_APPROVALS": "1"]) { a, _ in a }) == nil)
        #expect(MCPMissingEnvironment([:])?.names == ["VISOR_PORT", "VISOR_SESSION", "VISOR_TOKEN"])
        #expect(MCPMissingEnvironment(["VISOR_PORT": "7433", "VISOR_SESSION": "A", "VISOR_TOKEN": ""])?.names == ["VISOR_TOKEN"])
        #expect(MCPMissingEnvironment(["VISOR_URL": "ws://host:7433", "VISOR_SESSION": "A", "VISOR_TOKEN": "t"]) == nil,
                "a server given by its URL needs no port")
        #expect(MCPMissingEnvironment(["VISOR_URL": "ws://host:7433"])?.names == ["VISOR_SESSION", "VISOR_TOKEN"])
        #expect(MCPMissingEnvironment(["VISOR_PORT": "7433", "VISOR_SESSION": "A", "VISOR_TOKEN_FILE": "/tmp/t"]) == nil,
                "the token file stands for VISOR_TOKEN")

        let missing = MCPMissingEnvironment(["VISOR_APPROVALS": "1", "VISOR_PORT": "7433"])
        #expect(missing?.names == ["VISOR_SESSION", "VISOR_TOKEN"])
        let said = Said()
        missing?.answer(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#, to: said)
        missing?.answer(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: said)
        missing?.answer(#"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#, to: said)
        #expect(said.all.count == 2, "notifications get no answer")
        let first = said.all.first
        #expect(first?["id"] == .number(1))
        #expect(first?["result"].isNull ?? false)
        let message = first?["error"]["message"].string ?? ""
        #expect(message.contains("VISOR_SESSION, VISOR_TOKEN"), Comment(rawValue: message))
        #expect(message.contains("Claude Code must pass the agent's environment to its MCP servers"), Comment(rawValue: message))
        #expect(said.all.last?["id"] == .string("two"))
        #expect(said.all.last?["error"]["code"] == .number(-32002))
    }

    /// A real call, on a real WebSocket, to a real server: the sessions
    /// listed to an agent with the server's token; refused without it.
    @MainActor
    @Test func testACallReachesARealServer() async throws {
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
        #expect(server.listening)
        // The agent asking is one of the server's sessions, as any is.
        server.sessions = [("A", "Server work"), ("B", "Client work")].map { id, title in
            SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0),
                          process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        }

        let link = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: server.agentToken(for: "A"), session: "A")
        // On a Mac the Network framework's listener is ready a moment after
        // it is started (NWListener.start is asynchronous, `listening` is
        // set at once): the first call waits for it, up to three seconds.
        var reply = await link.call(["mode": .string("sessions")])
        for _ in 0..<30 where reply.text == "Visor is not reachable." {
            try await Task.sleep(for: .milliseconds(100))
            reply = await link.call(["mode": .string("sessions")])
        }
        #expect(reply.ok, Comment(rawValue: reply.text))
        #expect(reply.text.contains("B — Client work"), Comment(rawValue: reply.text))

        let stranger = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: "not-the-token", session: "A")
        let refused = await stranger.call(["mode": .string("sessions")])
        #expect(!refused.ok)

        // The token file (VISOR_TOKEN_FILE), read on each call: what the
        // server re-mints is taken, VISOR_TOKEN only without it.
        server.writeSessionToken(of: "A")
        let file = VisorServer.sessionTokenFile(of: "A").path
        let filed = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: "stale", session: "A", tokenFile: file)
        let fromFile = await filed.call(["mode": .string("sessions")])
        #expect(fromFile.ok, Comment(rawValue: fromFile.text))
        server.refreshSessionTokenFiles()
        #expect(filed.currentToken == (try String(contentsOfFile: file, encoding: .utf8)), "the re-minted one, read again")
        #expect((await filed.call(["mode": .string("sessions")])).ok)
        let noFile = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: server.agentToken(for: "A"), session: "A",
                                      tokenFile: file + ".missing")
        #expect((await noFile.call(["mode": .string("sessions")])).ok, "no file: VISOR_TOKEN")
        let asB = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: "", session: "B", tokenFile: file)
        #expect(!(await asB.call(["mode": .string("sessions")])).ok, "A's file, as B")

        let nobody = MCPWebSocketLink(url: "ws://127.0.0.1:\(ServerTestCase.freePort())", token: "", session: "A", redials: [])
        let unreachable = await nobody.call(["mode": .string("sessions")])
        #expect(unreachable == MCPReply(ok: false, text: "Visor is not reachable."))
    }

    /// A live session's MCP server (the bridge `visor-agent-host mcp` runs,
    /// on its real WebSocket link and token file) across a restart of the
    /// server under it, as an update or a crash makes one: while the server
    /// is gone its tools still list, at once; a call made then is dialled
    /// again until the new server answers it; afterwards its tools list and
    /// answer as before, and the agent was never told they changed.
    @MainActor
    @Test func testASessionsToolsListAndAnswerAcrossAServerRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        defer { VisorServer.socketPathOverride = nil }
        let port = ServerTestCase.freePort()
        var starts = 0
        func start() async throws -> VisorServer {
            starts += 1
            VisorServer.socketPathOverride = "/tmp/visor-mcp-\(ProcessInfo.processInfo.processIdentifier)-\(starts).sock"
            let server = VisorServer(port: port)
            server.password = "pearl-grove"
            for _ in 0..<60 where !server.listening { try await Task.sleep(for: .milliseconds(100)) }
            #expect(server.listening)
            server.sessions = [("A", "Server work"), ("B", "Client work")].map { id, title in
                SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0),
                              process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
            }
            return server
        }
        var server = try await start()
        server.writeSessionToken(of: "A")
        let link = MCPWebSocketLink(url: "ws://127.0.0.1:\(port)", token: "", session: "A",
                                    tokenFile: VisorServer.sessionTokenFile(of: "A").path)
        let said = Said()
        let timing = MCPTiming(heartbeat: .seconds(20), unanswered: .seconds(60), watch: .milliseconds(50), look: .seconds(2),
                               retry: .milliseconds(20))
        let bridge = MCPBridge(link: link, output: said, approvals: false, contained: false, timing: timing)
        defer { Task { await bridge.close() } }
        await bridge.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        _ = await said.answer(1)
        await bridge.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(names(await said.answer(2, within: 10)) == Self.own)
        await bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await bridge.handle(call(3, "list_sessions"))
        let before = await said.answer(3, within: 15)
        #expect((before?["result"]["isError"].bool) == false, Comment(rawValue: text(before) ?? "no answer"))
        #expect(text(before)?.contains("B — Client work") ?? false, Comment(rawValue: text(before) ?? ""))

        server.stop()
        await bridge.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        #expect(names(await said.answer(4, within: 0.5)) == Self.own, "the server gone: its tools still list, at once")
        await bridge.handle(call(5, "list_sessions"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(await said.answer(5, within: 0) == nil, "waiting for the server")

        server = try await start()
        defer { server.stop() }
        let during = await said.answer(5, within: 15)
        #expect((during?["result"]["isError"].bool) == false, Comment(rawValue: text(during) ?? "no answer"))
        #expect(text(during)?.contains("B — Client work") ?? false, "made while it was gone, answered by the new one")
        await bridge.handle(#"{"jsonrpc":"2.0","id":6,"method":"tools/list"}"#)
        #expect(names(await said.answer(6, within: 0.5)) == Self.own)
        await bridge.handle(call(7, "list_sessions"))
        let after = await said.answer(7, within: 10)
        #expect((after?["result"]["isError"].bool) == false, Comment(rawValue: text(after) ?? "no answer"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes(said) == 0, "nothing changed for the agent")
    }
}
}
