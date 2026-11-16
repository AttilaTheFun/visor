// A runner's agent as this server drives it, over gRPC as its wrapper and
// runner reach it (agent_protocol's AgentDriver and AgentDispatcher):
// every call shows the agent's own token (Job.token), and one that doesn't,
// or shows another agent's, is refused; its MCP requests are answered as
// its session's, with Visor's own tools and none of the computer's
// passed-on servers; its permission prompts are its session's, and the
// person's answers go back to it; its job says whether it asks
// (Job.skip_permissions), as its session does.

import AgentProtocol
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
@testable import VisorAgent
@testable import VisorDriver
import VisorMCPBridge
import VisorProtocol
@testable import VisorServer
import Testing

/// A wrapper's connection to the driver: what it sends up, what it is
/// sent, and how the call ended.
private final class FakeWrapper: Sendable {
    struct State {
        var down: [AgentProtocol_V1_DriverMessage] = []
        var code: RPCError.Code?
        var ended = false
    }

    let state = Mutex(State())
    private let upward: AsyncStream<AgentProtocol_V1_WrapperMessage>
    private let up: AsyncStream<AgentProtocol_V1_WrapperMessage>.Continuation

    init() {
        (upward, up) = AsyncStream.makeStream()
    }

    /// Dials the driver on `port`, showing `token` if any.
    @discardableResult
    func connect(port: Int, token: String?) -> Task<Void, Never> {
        let metadata = bearerMetadata(token)
        let upward = self.upward
        return Task {
            do {
                let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
                try await withGRPCClient(transport: transport) { client in
                    try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).connect(metadata: metadata, requestProducer: { writer in
                        for await message in upward { try await writer.write(message) }
                    }, onResponse: { response in
                        for try await message in response.messages { self.state.withLock { $0.down.append(message) } }
                    })
                }
            } catch {
                state.withLock { $0.code = (error as? RPCError)?.code ?? .unknown }
            }
            state.withLock { $0.ended = true }
        }
    }

    func send(_ message: AgentProtocol_V1_WrapperMessage) { up.yield(message) }

    func finish() { up.finish() }

    var down: [AgentProtocol_V1_DriverMessage] { state.withLock { $0.down } }

    /// The MCP answer under the wrapper's `id`, once it has come.
    @MainActor
    func mcp(_ id: String) async -> AgentProtocol_V1_McpResponse? {
        await eventually { self.down.first { $0.mcp.id == id && !id.isEmpty }?.mcp }
    }

    /// The answers to the approval `id`, once there are `count`.
    @MainActor
    func approvals(_ id: String, count: Int = 1) async -> [AgentProtocol_V1_Approval] {
        await eventually {
            let given = self.down.compactMap { message -> AgentProtocol_V1_Approval? in
                guard case .approval(let approval) = message.message, approval.requestID == id else { return nil }
                return approval
            }
            return given.count >= count ? given : nil
        } ?? []
    }
}

/// An MCP server this computer passes on to its sessions (gh, say): what
/// it was sent, kept; one tool, `pr_create`.
private final class PassedOnEndpoint: HTTPFetching {
    let heard = Mutex<[JSONValue]>([])

    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        let message = parseJSON(String(decoding: request.body, as: UTF8.self)) ?? .null
        heard.withLock { $0.append(message) }
        guard let id = message["id"].int else { return .init(status: 202, body: Data()) }
        let result: JSONValue
        switch message["method"].string ?? "" {
        case "initialize":
            result = .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])])])
        case "tools/list":
            result = .object(["tools": .array([.object(["name": .string("pr_create"), "inputSchema": .object(["type": .string("object")])])])])
        default:
            result = .object(["content": .array([.object(["type": .string("text"), "text": .string("made")])])])
        }
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result]).encoded()
        return .init(status: 200, body: Data(body.utf8), headers: ["content-type": "application/json"])
    }
}

/// A native session's MCP server reaching this server, as its own
/// (VisorServer.answerAgent, with its session's own agent token).
private struct NativeLink: MCPServerLink {
    let session: String
    let server: VisorServer

    func call(_ fields: [String: JSONValue]) async -> MCPReply {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                var message = fields
                message["type"] = .string("agent")
                message["token"] = .string(server.agentToken(for: session))
                message["client"] = .string(session)
                message["id"] = .string(UUID().uuidString)
                guard let envelope = Envelope.decode(JSONValue.object(message).encoded()) else {
                    return continuation.resume(returning: MCPReply(ok: false, text: "unreadable"))
                }
                server.answerAgent(envelope) { reply in
                    let error = reply.error ?? ""
                    continuation.resume(returning: MCPReply(ok: error.isEmpty, text: error.isEmpty ? reply.text ?? "" : error))
                }
            }
        }
    }

    func ask(_ request: [String: JSONValue], _ asking: MCPAsking) async -> MCPAnswer { .no }
}

/// What a native session's MCP server said to its agent.
private final class NativeSaid: MCPOutput {
    let all = Mutex<[JSONValue]>([])

    func send(_ message: JSONValue) { all.withLock { $0.append(message) } }

    func answer(_ id: Int) async -> JSONValue? {
        await eventually { self.all.withLock { $0.first { $0["id"] == .number(Double(id)) } } }
    }
}

/// What a call shows: `token` as a bearer, or nothing.
private func bearerMetadata(_ token: String?) -> Metadata {
    var metadata = Metadata()
    if let token { metadata.addString("Bearer \(token)", forKey: "authorization") }
    return metadata
}

/// `value` once it is there, within five seconds.
@MainActor
private func eventually<T>(_ value: () -> T?) async -> T? {
    for _ in 0..<500 {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

extension ServerTests {
@Suite(.serialized) @MainActor final class DrivenAgentTests {
    private var server: VisorServer!
    private var listening: VisorDriver.Listening!
    private var root: URL!
    private let port = Int(ServerTestCase.freePort())

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-driven-agents-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: UInt16(ServerTestCase.freePort()))
        listening = VisorDriver.Listening(host: "127.0.0.1", port: port, url: "http://127.0.0.1:\(port)", harness: "echo")
        listening.serve(server)
        // Listening once a claim is answered.
        for _ in 0..<200 {
            do {
                _ = try await claimed()
                break
            } catch {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    isolated deinit {
        listening.stop()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private var jobs: JobQueue { listening.jobs! }

    private func start(_ title: String, skip: Bool? = nil) -> Envelope {
        var e = Envelope(type: "job")
        e.agent = .claude
        e.title = title
        e.cwd = "/tmp"
        e.skipPermissions = skip
        return e
    }

    private func dispatcher<T: Sendable>(_ body: @escaping @Sendable (AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws -> T)
        async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        return try await withGRPCClient(transport: transport) { client in
            try await body(AgentProtocol_V1_AgentDispatcher.Client(wrapping: client))
        }
    }

    /// The next job a native runner is given, if any (claimed over gRPC).
    /// The next job, claimed by a runner of these capabilities: a native
    /// one unless told.
    private func claimed(_ capabilities: [String] = ["native", "harness:echo"]) async throws -> AgentProtocol_V1_Job? {
        let answer = try await dispatcher { try await $0.claim(.with { $0.runner = "Test"; $0.capabilities = capabilities }) }
        return answer.hasJob ? answer.job : nil
    }

    /// How a call ended: nil when it was answered.
    private func code<T: Sendable>(_ call: @escaping @Sendable (AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws -> T)
        async -> RPCError.Code? {
        do {
            _ = try await dispatcher(call)
            return nil
        } catch {
            return (error as? RPCError)?.code ?? .unknown
        }
    }

    private nonisolated static func hello(_ agent: String, title: String = "Driven") -> AgentProtocol_V1_WrapperMessage {
        .with { $0.hello = .with {
            $0.agent = .with { $0.uuid = agent; $0.dispatcherURL = "http://127.0.0.1" }
            $0.spec = .with { $0.harness = "echo"; $0.title = title; $0.workingDirectory = "/tmp" }
            $0.hostName = "test"
        } }
    }

    /// A wrapper dialled in for `agent` with `token`, said hello and hung
    /// up: how its call ended.
    private func refusal(connecting agent: String, token: String?) async -> RPCError.Code? {
        let wrapper = FakeWrapper()
        let call = wrapper.connect(port: port, token: token)
        wrapper.send(Self.hello(agent))
        wrapper.finish()
        await call.value
        return wrapper.state.withLock { $0.code }
    }

    /// The job `title`'s agent dialled in as its wrapper, with its token:
    /// its job, its connection, and its session.
    private func driven(_ title: String, runner capabilities: [String] = ["native", "harness:echo"])
        async throws -> (AgentProtocol_V1_Job, FakeWrapper, SessionRecord) {
        _ = try jobs.queueStart(start(title)).get()
        let job = try #require(try await claimed(capabilities))
        let wrapper = FakeWrapper()
        wrapper.connect(port: port, token: job.token)
        wrapper.send(Self.hello(job.agent.uuid, title: title))
        let record = try #require(await eventually { self.server.session(job.agent.uuid) }, "its session taken in")
        return (job, wrapper, record)
    }

    @Test func aCallWithoutItsAgentsTokenIsRefused() async throws {
        let a = try jobs.queueStart(start("A")).get()
        let b = try jobs.queueStart(start("B")).get()
        let jobA = try #require(try await claimed())
        let jobB = try #require(try await claimed())
        #expect(jobA.agent.uuid == a && jobB.agent.uuid == b)
        #expect(!jobA.token.isEmpty && !jobB.token.isEmpty && jobA.token != jobB.token, "each its own")

        // Connect: no token, a wrong one, and B's as A.
        #expect(await refusal(connecting: a, token: nil) == .unauthenticated)
        #expect(await refusal(connecting: a, token: "not-a-token") == .unauthenticated)
        #expect(await refusal(connecting: a, token: jobB.token) == .unauthenticated, "B's token can't dial in as A")
        #expect(await refusal(connecting: "someone-else", token: jobA.token) == .unauthenticated, "nor A's as an agent of no job")
        #expect(server.session(a) == nil && server.session(b) == nil, "no session taken in for any of them")

        // Report and Renew, the wrapper's and the runner's.
        let started = AgentProtocol_V1_JobReport.with { $0.agent = jobA.agent; $0.started = .with { $0.runner = "Test"; $0.sessionID = "s" } }
        #expect(await code { try await $0.report(started) } == .unauthenticated)
        #expect(await code { try await $0.report(started, metadata: bearerMetadata(jobB.token)) } == .unauthenticated)
        let renewal = AgentProtocol_V1_RenewRequest.with { $0.agent = jobA.agent }
        #expect(await code { try await $0.renew(renewal) } == .unauthenticated)
        #expect(await code { try await $0.renew(renewal, metadata: bearerMetadata(jobB.token)) } == .unauthenticated)
        let renewed = try await dispatcher { try await $0.renew(renewal, metadata: bearerMetadata(jobA.token)) }
        #expect(renewed.hasClaimExpires, "with its own token, the claim is kept")
        #expect(await code { try await $0.report(started, metadata: bearerMetadata(jobA.token)) } == nil)

        // Conversation.
        let conversation = AgentProtocol_V1_ConversationRequest.with { $0.agent = jobA.agent; $0.workingDirectory = "/tmp" }
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        let refused: RPCError.Code? = await {
            do {
                try await withGRPCClient(transport: transport) { client in
                    try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).conversation(conversation) { response in
                        for try await _ in response.messages {}
                    }
                }
                return nil
            } catch {
                return (error as? RPCError)?.code ?? .unknown
            }
        }()
        #expect(refused == .unauthenticated)

        // With its own, A dials in and is its session.
        let wrapper = FakeWrapper()
        wrapper.connect(port: port, token: jobA.token)
        wrapper.send(Self.hello(a, title: "A"))
        let record = await eventually { self.server.session(a) }
        #expect((record?.driven) == true)
        wrapper.finish()

        // A job let go takes its token with it: its runner's renewal is
        // told the claim isn't its own, and its wrapper can't dial in.
        jobs.forget(session: b)
        let gone = try await dispatcher { try await $0.renew(.with { $0.agent = jobB.agent }, metadata: bearerMetadata(jobB.token)) }
        #expect(!gone.hasClaimExpires)
        #expect(await refusal(connecting: b, token: jobB.token) == .unauthenticated)
    }

    /// The fresh tokens a wrapper was sent (DriverMessage.token).
    private func freshTokens(_ wrapper: FakeWrapper) -> [String] {
        wrapper.down.compactMap { message in
            guard case .token(let token) = message.message else { return nil }
            return token
        }
    }

    /// A connected wrapper is sent a fresh token a sixth of its token's
    /// life before it ends (ten minutes of an hour), again and again.
    @Test func aWrapperIsSentAFreshTokenBeforeItsOwnEnds() async throws {
        server.agentTokens.runnerAgentLifetime = 1.2
        let (job, wrapper, record) = try await driven("Refreshed")
        let first = try #require(await eventually { self.freshTokens(wrapper).first })
        #expect(first != job.token)
        let claims = try server.agentTokens.verify(first, as: .runnerAgent, agent: job.agent.uuid).get()
        #expect(claims.sub == record.info.id && claims.agent == job.agent.uuid)
        let second = await eventually { self.freshTokens(wrapper).count >= 2 ? self.freshTokens(wrapper)[1] : nil }
        #expect(second != nil && second != first, "and again before that one ends")
        // Its next connection, with the fresh one, is let in.
        #expect(jobs.access(job.agent.uuid, bearer: try #require(second)) == .granted)
        wrapper.finish()
    }

    /// A wrapper away longer than its token lasts is refused when it dials
    /// back in, and its session carried on by a new job with a fresh token
    /// (#437's resume); its runner's renewals were taken meanwhile.
    @Test func aWrapperReconnectingWithAnExpiredTokenIsRefusedAndItsSessionCarriedOnAfresh() async throws {
        let move = AgentJobMove(agent: "m1", session: "moved", title: "Moved", resume: "c-1", cwd: "/tmp", runsOn: "native")
        let record = server.takeDriven(SessionInfo(id: "moved", agent: .claude, cwd: "/tmp", title: "Moved", created: 0), process: DrivenProcess())
        record.move = move
        #expect(jobs.queueResume(move) == .success("moved"))
        let job = try #require(try await claimed())
        #expect(job.agent.uuid == "m1")
        let expired = server.agentTokens.mint(.runnerAgent, session: "moved", agent: "m1", now: Date().addingTimeInterval(-7200))
        let renewed = try await dispatcher { try await $0.renew(.with { $0.agent = job.agent }, metadata: bearerMetadata(expired)) }
        #expect(renewed.hasClaimExpires, "a runner's renewal shows the token its claim gave it: taken past its end")

        #expect(await refusal(connecting: "m1", token: expired) == .unauthenticated)
        let next = try #require(await eventually { record.move.flatMap { $0.agent != "m1" ? $0.agent : nil } }, "a new agent for it")
        #expect(!jobs.holds("m1"), "the old agent's job let go")
        #expect(jobs.holds(next) && record.driven, "the session still driven, its new job queued")
        let fresh = try #require(try await claimed())
        #expect(fresh.agent.uuid == next)
        #expect((try? server.agentTokens.verify(fresh.token, as: .runnerAgent, agent: next).get())?.sub == "moved")
        #expect(await refusal(connecting: "m1", token: job.token) == .unauthenticated, "the old agent's own is let go with its job")
    }

    @Test func aWrappersMCPIsAnsweredAsItsSession() async throws {
        server.takeDriven(SessionInfo(id: "other-session", agent: .claude, cwd: "/tmp", title: "Other", created: 0), process: DrivenProcess())
        // In a container: Visor's own tools, answered as its session by
        // its driver, never with a session token (a REST credential).
        let (job, wrapper, _) = try await driven("Asker", runner: ["container", "harness:echo"])
        func request(_ id: String, _ json: String) -> AgentProtocol_V1_WrapperMessage {
            .with { $0.mcp = .with { $0.id = id; $0.json = json; $0.client = "c1" } }
        }
        wrapper.send(request("w1", #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        wrapper.send(request("", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        wrapper.send(request("w2", #"{"jsonrpc":"2.0","id":"two","method":"tools/list"}"#))
        wrapper.send(request("w3", #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}"#))
        wrapper.send(request("w4", "not json"))

        let initialized = try #require(await wrapper.mcp("w1"))
        #expect(initialized.client == "c1")
        let hello = try #require(parseJSON(initialized.json))
        #expect(hello["id"] == .number(1))
        #expect(hello["result"]["serverInfo"]["name"].string == "visor")
        #expect(hello["result"]["protocolVersion"].string == "2025-06-18")

        let listing = try #require(await wrapper.mcp("w2"))
        let listed = try #require(parseJSON(listing.json))
        #expect(listed["id"] == .string("two"), "the agent's own id, whatever its kind")
        let tools = listed["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(tools.contains("list_sessions") && tools.contains("send_message") && tools.contains("read_inbox"))
        #expect(!tools.contains("approve"), "the wrapper's own")

        let calling = try #require(await wrapper.mcp("w3"))
        let call = try #require(parseJSON(calling.json))
        let text = call["result"]["content"][0]["text"].string ?? ""
        #expect(call["result"]["isError"] == .bool(false), Comment(rawValue: text))
        #expect(text.contains("other-session"), Comment(rawValue: text))
        #expect(!text.contains(job.agent.uuid), "its own session isn't another: it asks as itself")
        #expect(server.sessionAgentTokens[job.agent.uuid] == nil, "no session token minted for a runner's agent")

        let refusing = try #require(await wrapper.mcp("w4"))
        let unreadable = try #require(parseJSON(refusing.json))
        #expect(unreadable["error"]["code"] == .number(-32700))
        #expect(!wrapper.down.contains { $0.mcp.id.isEmpty && $0.mcp.json.contains("notifications/initialized") }, "a notification isn't answered")
        wrapper.finish()
    }

    /// Logan (2026-11-16): a container's agent gets Visor's MCP through its
    /// wrapper and Shireworks' from its container, never this computer's
    /// passed-on servers, whatever its session's switches say. A session
    /// on Visor's own native runner, and a native session, still have them.
    @Test func aContainersWrapperGetsVisorsOwnToolsNotThePassedOn() async throws {
        let endpoint = PassedOnEndpoint()
        ServerPlatform.current.fetching = endpoint
        server.settings.mcpEndpoints = [MCPEndpoint(name: "gh", url: "http://127.0.0.1:7470/mcp")]
        let (job, wrapper, record) = try await driven("Contained", runner: ["container", "harness:echo"])
        #expect(jobs.runsInContainer(job.agent.uuid))
        #expect(record.runsInContainer)
        #expect(record.info.mcp == [MCPSwitch(name: "gh", on: true)], "its switch says on")
        func request(_ id: String, _ json: String) -> AgentProtocol_V1_WrapperMessage {
            .with { $0.mcp = .with { $0.id = id; $0.json = json; $0.client = "c1" } }
        }
        wrapper.send(request("w1", #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        wrapper.send(request("", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        wrapper.send(request("w2", #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        wrapper.send(request("w3", #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gh__pr_create","arguments":{}}}"#))

        let listing = try #require(await wrapper.mcp("w2"))
        let tools = parseJSON(listing.json)?["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(tools.contains("list_sessions") && tools.contains("send_message") && tools.contains("read_inbox"), "Visor's own")
        #expect(!tools.contains { $0.contains("__") }, "no passed-on tools: \(tools)")

        let calling = try #require(await wrapper.mcp("w3"))
        let call = try #require(parseJSON(calling.json))
        let text = call["result"]["content"][0]["text"].string ?? ""
        #expect(call["result"]["isError"] == .bool(true), Comment(rawValue: text))
        #expect(text.contains("isn't one of Visor's tools"), Comment(rawValue: text))
        #expect(endpoint.heard.withLock { $0.isEmpty }, "the endpoint never asked on its behalf")
        wrapper.finish()

        // Driven, on Visor's own native runner: on this computer, as any
        // native session, so it has them.
        let (nativeJob, nativeWrapper, nativeRecord) = try await driven("On the native runner")
        #expect(!jobs.runsInContainer(nativeJob.agent.uuid))
        #expect(await eventually { nativeRecord.runsInContainer ? nil : true } == true)
        nativeWrapper.send(request("n1", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let nativeListing = try #require(await nativeWrapper.mcp("n1"))
        let nativeRunnerTools = parseJSON(nativeListing.json)?["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(nativeRunnerTools.contains("gh__pr_create"), "a native runner's session lists them: \(nativeRunnerTools)")
        nativeWrapper.send(request("n2", #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gh__pr_create","arguments":{}}}"#))
        let nativeCall = try #require(await nativeWrapper.mcp("n2"))
        #expect((parseJSON(nativeCall.json)?["result"]["content"][0]["text"].string) == "made")
        nativeWrapper.finish()

        // A native session, through Visor's MCP as it runs one here.
        let native = SessionRecord(info: SessionInfo(id: "native-session", agent: .claude, cwd: "/tmp", title: "Native", created: 0),
                                   process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
        server.sessions.append(native)
        let said = NativeSaid()
        let bridge = MCPBridge(link: NativeLink(session: native.info.id, server: server), output: said, approvals: false, contained: false)
        await bridge.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let nativeTools = await said.answer(4)?["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(nativeTools.contains("gh__pr_create"), "a native session's are unchanged: \(nativeTools)")
        await bridge.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gh__pr_create","arguments":{}}}"#)
        let made = await said.answer(5)
        #expect((made?["result"]["content"][0]["text"].string) == "made")
        await bridge.close()
    }

    @Test func aWrappersApprovalsAreItsSessionsAndTheAnswersGoBack() async throws {
        let (job, wrapper, record) = try await driven("Asks first")
        let session = job.agent.uuid
        func ask(_ id: String, _ tool: String, _ input: String = "{}") {
            wrapper.send(.with { $0.approval = .with { $0.id = id; $0.tool = tool; $0.summary = "\(tool) it"; $0.inputJson = input } })
        }
        func answer(_ id: String, allow: Bool, answers: [String: String]? = nil) {
            var e = Envelope(type: "approve")
            e.session = session
            e.id = id
            e.allow = allow
            e.answers = answers
            server.perform(e, from: nil)
        }
        func pending(_ id: String?) async -> Bool {
            await eventually { record.info.pendingApproval?.id == id ? true : nil } ?? false
        }

        ask("p1", "Bash", #"{"command":"ls"}"#)
        #expect(await pending("p1"))
        #expect(record.info.pendingApproval == ApprovalRequest(id: "p1", tool: "Bash", summary: "Bash it"))
        answer("p1", allow: true)
        #expect(await wrapper.approvals("p1") == [.with { $0.requestID = "p1"; $0.allow = true }])
        #expect(record.info.pendingApproval == nil)

        ask("p2", "Edit")
        #expect(await pending("p2"))
        answer("p2", allow: false)
        #expect(await wrapper.approvals("p2") == [.with { $0.requestID = "p2"; $0.reason = "The user denied this from Visor." }])

        ask("p3", "AskUserQuestion", #"{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}]}]}"#)
        #expect(await pending("p3"))
        #expect((record.info.pendingApproval?.questions?.first?.question) == "Which?")
        answer("p3", allow: true, answers: ["Which?": "B"])
        let updated = parseJSON(await wrapper.approvals("p3").first?.updatedInputJson ?? "")
        #expect((updated?["answers"]["Which?"].string) == "B")
        #expect((updated?["questions"][0]["question"].string) == "Which?")

        ask("p4", "Write")
        #expect(await pending("p4"))
        wrapper.send(.with { $0.approvalWithdrawn = "p4" })
        #expect(await pending(nil), "withdrawn: no longer asked")

        // Asked again after a reconnect: the answer given, again.
        ask("p1", "Bash", #"{"command":"ls"}"#)
        #expect(await wrapper.approvals("p1", count: 2).count == 2)
        #expect(record.info.pendingApproval == nil, "not shown again")
        wrapper.finish()
    }

    @Test func aJobAsksOrNotAsItsSessionDoes() async throws {
        // A job queued as such.
        _ = try jobs.queueStart(start("Acts", skip: true)).get()
        _ = try jobs.queueStart(start("Asks")).get()
        // Said either way, false included, as the runner reads it off the
        // wire: a job without it is an old dispatcher's, and would act.
        let acts = try #require(try await claimed())
        #expect(acts.hasSkipPermissions && acts.skipPermissions)
        let asks = try #require(try await claimed())
        #expect(asks.hasSkipPermissions, "false is said, not left out")
        #expect(!asks.skipPermissions, "asks unless it says otherwise")

        // A driven session's next agent: as the session is set.
        let record = server.takeDriven(SessionInfo(id: "moved", agent: .claude, cwd: "/tmp", title: "Moved", skipPermissions: true, created: 0),
                                       process: DrivenProcess())
        record.move = AgentJobMove(agent: "old-agent", session: "moved", title: "Moved", resume: "c-1", cwd: "/tmp", runsOn: "native")
        var manual = Envelope(type: "permissions")
        manual.session = "moved"
        manual.skipPermissions = false
        server.perform(manual, from: nil)
        let asking = try #require(try await claimed())
        #expect(asking.hasSkipPermissions, "a manual session's job says false")
        #expect(!asking.skipPermissions && asking.resumeSessionID == "c-1" && !asking.token.isEmpty)
        #expect(jobs.session(of: asking.agent.uuid) == "moved")

        var auto = manual
        auto.skipPermissions = true
        server.perform(auto, from: nil)
        let acting = try #require(try await claimed())
        #expect(acting.hasSkipPermissions && acting.skipPermissions && acting.agent.uuid != asking.agent.uuid)
        #expect(record.move?.skipPermissions == true)
    }
}
}
