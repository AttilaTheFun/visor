// Sessions placed in the Sessions container (the container runner,
// VisorServer+ContainerRunner), driven over gRPC as their wrappers reach
// the driver, with a container that runs no VM: what it's asked to start is
// kept, and a wrapper of the test's dials in with the token it was given.
// The pilot's seven checks (18 Nov), as tests:
//
// 1. Its MCP: Visor's own tools, as its session, none passed on.
// 2. Mail both ways: sent as its session, received as an `@@from` turn.
// 3. Approvals: a session that asks has its prompts answered from Visor.
// 4. Interrupt: down its stream.
// 5. Restart survival: a server's start starts its agent again, on its
//    latest conversation, a turn cut short picked up by a nudge.
// 6. The move itself, and its token's enforcement: its own token in, no
//    other; no claim, no job.
// 7. Move Back with its conversation (the hand-back), into this
//    computer's Claude folder, and the session carries on from it here.
//
// And its lifecycle: an agent that ends is started again, three quick ends
// stop it, a container held stopped stops it, Stop Agent and Start Agent,
// and a move refused, or one whose agent can't start coming straight back.

import AgentProtocol
import ClaudeTranscript
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization
@testable import VisorAgent
@testable import VisorDriver
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent started in the fake container: ended by the test, or by a
/// signal.
private final class FakeRun: ContainerAgentRun {
    private struct State {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var signals: [Int32] = []
    }

    private let state = Mutex(State())

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { held -> Int32? in
                if let status = held.status { return status }
                held.waiters.append(continuation)
                return nil
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }

    func signal(_ number: Int32) async {
        state.withLock { $0.signals.append(number) }
        end(128 + number)
    }

    /// Ended with `status`, once.
    func end(_ status: Int32) {
        let waiters = state.withLock { held -> [CheckedContinuation<Int32, Never>] in
            guard held.status == nil else { return [] }
            held.status = status
            defer { held.waiters = [] }
            return held.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    var signals: [Int32] { state.withLock { $0.signals } }
    var hasEnded: Bool { state.withLock { $0.status != nil } }
}

/// The Sessions container with no VM: how it stands is the test's, and
/// each agent it's asked to start is kept.
private final class FakeContainer: SessionsContainer {
    struct Started: Sendable {
        let agent: ContainerAgent
        let run: FakeRun
    }

    let standing = Mutex(ContainerStatus(state: .running, enabled: true, canRun: true, since: 1))
    let started = Mutex<[Started]>([])
    /// Why a start is refused, while it is.
    let refusing = Mutex<String?>(nil)
    let shared: [String]

    init(shared: [String]) { self.shared = shared }

    func status() async -> ContainerStatus { standing.withLock { $0 } }
    func start() async -> ContainerStatus { standing.withLock { $0 } }
    func stop() async -> ContainerStatus { standing.withLock { $0 } }
    func restart() async -> ContainerStatus { standing.withLock { $0 } }
    var sharedFolders: [String] { shared }

    func startAgent(_ agent: ContainerAgent) async throws -> any ContainerAgentRun {
        if let why = refusing.withLock({ $0 }) { throw Refusal(why: why) }
        let run = FakeRun()
        started.withLock { $0.append(Started(agent: agent, run: run)) }
        return run
    }

    func settingsChanged(_ settings: ServerSettings) {}
    func loopbackPortIsFree(_ port: Int) -> Bool { true }

    var all: [Started] { started.withLock { $0 } }

    struct Refusal: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }
}

/// A wrapper's connection to the driver: what it is sent, and how its call
/// ended.
private final class Wrapper: Sendable {
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

    @discardableResult
    func connect(port: Int, token: String?) -> Task<Void, Never> {
        let metadata = bearer(token)
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

    /// Whether it was sent a message of this kind.
    func got(_ kind: (AgentProtocol_V1_DriverMessage.OneOf_Message) -> Bool) -> Bool {
        down.contains { $0.message.map(kind) ?? false }
    }

    /// The texts it was sent to say.
    var sent: [String] {
        down.compactMap { message in
            guard case .send(let send) = message.message else { return nil }
            return send.text
        }
    }
}

/// What a call shows: `token` as a bearer, or nothing.
private func bearer(_ token: String?) -> Metadata {
    var metadata = Metadata()
    if let token { metadata.addString("Bearer \(token)", forKey: "authorization") }
    return metadata
}

/// Why the server refused, or nil when it took it.
private func refusal(_ result: Result<Void, AgentJobRefusal>) -> String? {
    if case .failure(let refused) = result { return refused.reason }
    return nil
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

/// An agent of this computer's with a conversation, for a session about to
/// move into the container.
@MainActor
private final class HostAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    var skipPermissions = false
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    let conversation: String
    var resumeID: String? { conversation }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    private(set) var ended = false
    private(set) var sent: [String] = []

    init(conversation: String) {
        self.conversation = conversation
        (events, _) = AsyncStream.makeStream()
    }

    func send(_ text: String) throws { sent.append(text) }
    func start() throws {}
    func interrupt() {}
    func stop() {}
    func end(within deadline: Duration) async { ended = true }
}

extension ServerTests {
@Suite(.serialized) @MainActor final class ContainerRunnerTests {
    private var server: VisorServer!
    private var listening: VisorDriver.Listening!
    private var container: FakeContainer!
    private var root: URL!
    private var sessions: URL!
    private var savedHome: URL!
    private let port = Int(ServerTestCase.freePort())
    private let conversation = "11111111-2222-4333-8444-555555555555"

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-runner-" + UUID().uuidString)
        sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        savedHome = ClaudeSessionFiles.home
        ClaudeSessionFiles.home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: ClaudeSessionFiles.home, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: UInt16(ServerTestCase.freePort()))
        listening = VisorDriver.Listening(host: "127.0.0.1", port: port, url: "http://127.0.0.1:\(port)", harness: "echo")
        listening.serve(server)
        container = FakeContainer(shared: [sessions.path])
        server.sessionsContainer = container
        server.containerRunner.releaseGrace = .milliseconds(200)
        // Listening once a call is answered (refused: it shows no token).
        for _ in 0..<200 {
            let probe = Wrapper()
            await probe.connect(port: port, token: nil).value
            if probe.state.withLock({ $0.code }) == .unauthenticated { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    isolated deinit {
        listening.stop()
        server.stop()
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    /// A session of this computer's, working in a folder on Sessions, with
    /// its conversation's file here.
    private func hostSession(_ id: String, skip: Bool = false) throws -> (SessionRecord, HostAgent) {
        let cwd = sessions.appendingPathComponent("Claude/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let agent = HostAgent(conversation: conversation)
        let record = SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: cwd.path, title: "Here \(id)", skipPermissions: skip,
                                                     created: 0), process: agent)
        server.sessions.append(record)
        let project = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd.path))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"role":"user","content":"before the move"}}"#.utf8 + [0x0A])
            .write(to: project.appendingPathComponent("\(conversation).jsonl"))
        return (record, agent)
    }

    /// `id` moved into the container, and its agent's wrapper dialled in
    /// with the token it was started with: what it was started with, its
    /// wrapper, and its record.
    private func placed(_ id: String, skip: Bool = false) async throws -> (FakeContainer.Started, Wrapper, SessionRecord) {
        let (record, _) = try hostSession(id, skip: skip)
        let result = await server.moveToContainer(id)
        if let refused = refusal(result) { Issue.record("refused: \(refused)") }
        let started = try #require(container.all.last { $0.agent.session == id })
        let wrapper = dial(started)
        #expect(await eventually { record.info.agentState == .running ? true : nil } == true, "running once its wrapper is in")
        return (started, wrapper, record)
    }

    /// The wrapper of `started` dialled in, saying it carries on `session`.
    private func dial(_ started: FakeContainer.Started, session: String = "c-in-container") -> Wrapper {
        let wrapper = Wrapper()
        wrapper.connect(port: port, token: started.agent.token)
        wrapper.send(hello(started.agent.agent, folder: started.agent.workingDirectory, session: session))
        return wrapper
    }

    private func hello(_ agent: String, folder: String, session: String) -> AgentProtocol_V1_WrapperMessage {
        .with { $0.hello = .with {
            $0.protocol = 2
            $0.agent = .with { $0.uuid = agent; $0.dispatcherURL = "http://127.0.0.1:7434" }
            $0.spec = .with { $0.harness = "claude"; $0.title = "Placed"; $0.workingDirectory = folder }
            $0.sessionID = session
            $0.hostName = "visor-sessions"
        } }
    }

    /// Check 6: the move, its agent started in the container with its own
    /// token, nothing claimed, and the token taken alone from its agent.
    @Test func moveToContainerStartsItsAgentThereWithItsOwnToken() async throws {
        let (started, wrapper, record) = try await placed("m1")
        let agent = started.agent
        #expect(record.driven && record.info.placement == .container)
        #expect(record.move?.runsOn == ContainerRunner.runsOn && record.move?.agent == agent.agent)
        #expect(agent.session == "m1" && agent.resumeSessionID == conversation)
        #expect(agent.workingDirectory == record.move?.cwd, "a folder on Sessions is kept: the container shares it at the same path")
        #expect(agent.sources.isEmpty && agent.sourcesDirectory == nil, "nothing to clone")
        #expect(agent.skipPermissions && record.info.skipPermissions, "the container is its sandbox")
        #expect(agent.environment["CLAUDE_CONFIG_DIR"] == sessions.path + "/.claude", "its Claude folder on Sessions")
        #expect(agent.harness == "echo", "the driver's harness")
        guard case .success(let claims) = server.agentTokens.verify(agent.token, as: .runnerAgent, agent: agent.agent, scope: .job) else {
            Issue.record("its token isn't a runner agent's")
            return
        }
        #expect(claims.sub == "m1")
        #expect(listening.jobs?.holds(agent.agent) == false, "no job: nothing claims it")
        #expect(await eventually { record.move?.conversation == "c-in-container" ? true : nil } == true, "the session its hello said is kept")

        // Another agent's token, or none, isn't let in as it.
        for token in [nil, "not-a-token", server.agentTokens.mint(.runnerAgent, session: "m1", agent: UUID().uuidString)] {
            let other = Wrapper()
            let call = other.connect(port: port, token: token)
            other.send(hello(agent.agent, folder: agent.workingDirectory, session: "x"))
            other.finish()
            await call.value
            #expect(other.state.withLock { $0.code } == .unauthenticated)
        }

        // Its conversation, for the folder it works in there.
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        let places = try await withGRPCClient(transport: transport) { client in
            try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).conversation(.with {
                $0.agent = .with { $0.uuid = agent.agent }
                $0.workingDirectory = agent.workingDirectory
                $0.harness = "claude"
            }, metadata: bearer(agent.token)) { response in
                var places: [String] = []
                for try await piece in response.messages where piece.last { places.append(piece.place) }
                return places
            }
        }
        #expect(places.contains { $0.hasSuffix("/\(conversation).jsonl") }, "\(places)")

        let again = await server.moveToContainer("m1")
        #expect(refusal(again) == "“Here m1” is in the Sessions container already.")
        wrapper.finish()
    }

    /// Check 1: its MCP is Visor's own tools, none of the passed-on.
    @Test func itsMCPIsVisorsOwnTools() async throws {
        server.settings.mcpEndpoints = [MCPEndpoint(name: "gh", url: "http://127.0.0.1:7470/mcp")]
        let (_, wrapper, record) = try await placed("mcp")
        #expect(record.runsInContainer)
        wrapper.send(.with { $0.mcp = .with { $0.id = "w1"; $0.json = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#; $0.client = "c" } })
        let listing = try #require(await eventually { wrapper.down.first { $0.mcp.id == "w1" }?.mcp })
        let tools = parseJSON(listing.json)?["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        #expect(tools.contains("send_message") && tools.contains("read_inbox") && tools.contains("list_sessions"))
        #expect(!tools.contains { $0.contains("__") }, "no passed-on tools: \(tools)")
        wrapper.finish()
    }

    /// Check 2: mail both ways.
    @Test func mailGoesBothWays() async throws {
        let (host, hostAgent) = try hostSession("mail-host")
        let (_, wrapper, record) = try await placed("mail-in")
        // Out: sent as its session, into the other's inbox.
        let sent = await server.answerDrivenAgent("mail-in", fields: ["mode": .string("send"), "session": .string("mail-host"),
                                                                       "text": .string("from the container")])
        #expect(sent.ok, Comment(rawValue: sent.text))
        #expect(host.mailbox.unread == 1 || hostAgent.sent.contains { $0.contains("from the container") })
        // In: a turn beginning @@from, down its stream.
        let from = RelayEndpoint(server: server.id, serverName: server.hostName, session: "mail-host", sessionName: "Here mail-host")
        _ = server.mail("to the container", from: from, to: record, messageID: UUID().uuidString, here: true)
        #expect(await eventually { wrapper.sent.contains { $0.contains("@@from") && $0.contains("to the container") } ? true : nil } == true,
                "\(wrapper.sent)")
        wrapper.finish()
    }

    /// Check 3: a session that asks has its prompts answered from Visor.
    @Test func approvalsAreAnsweredFromVisor() async throws {
        let (started, wrapper, record) = try await placed("asks")
        #expect(started.agent.skipPermissions)
        // Set to ask: its next agent asks, and its prompts are the session's.
        var manual = Envelope(type: "permissions")
        manual.session = "asks"
        manual.skipPermissions = false
        server.perform(manual, from: nil)
        let next = try #require(await eventually { self.container.all.count == 2 ? self.container.all[1] : nil })
        #expect(!next.agent.skipPermissions, "it asks")
        #expect(started.run.signals.isEmpty || started.run.hasEnded, "the one before let go")
        wrapper.finish()
        let asking = dial(next)
        asking.send(.with { $0.approval = .with { $0.id = "p1"; $0.tool = "Bash"; $0.summary = "Bash it"; $0.inputJson = #"{"command":"ls"}"# } })
        #expect(await eventually { record.info.pendingApproval?.id == "p1" ? true : nil } == true)
        var allow = Envelope(type: "approve")
        allow.session = "asks"
        allow.id = "p1"
        allow.allow = true
        server.perform(allow, from: nil)
        #expect(await eventually { asking.down.contains { $0.approval.requestID == "p1" && $0.approval.allow } ? true : nil } == true)
        asking.send(.with { $0.approval = .with { $0.id = "p2"; $0.tool = "Edit"; $0.summary = "Edit it"; $0.inputJson = "{}" } })
        #expect(await eventually { record.info.pendingApproval?.id == "p2" ? true : nil } == true)
        var deny = allow
        deny.id = "p2"
        deny.allow = false
        server.perform(deny, from: nil)
        #expect(await eventually { asking.down.contains { $0.approval.requestID == "p2" && !$0.approval.allow } ? true : nil } == true)
        asking.finish()
    }

    /// Check 4: an interrupt goes down its stream.
    @Test func anInterruptGoesDownItsStream() async throws {
        let (_, wrapper, _) = try await placed("interrupt")
        var stop = Envelope(type: "stop")
        stop.session = "interrupt"
        server.perform(stop, from: nil)
        #expect(await eventually { wrapper.got { if case .interrupt = $0 { true } else { false } } ? true : nil } == true)
        wrapper.finish()
    }

    /// Check 5: a server's start starts its agent again, once the engine
    /// is given, on its latest conversation, a turn cut short picked up.
    @Test func aServerStartStartsItsAgentAgainOnItsLatestConversation() async throws {
        let (started, wrapper, record) = try await placed("survives")
        #expect(await eventually { record.move?.conversation == "c-in-container" ? true : nil } == true)
        record.interrupted = true
        server.saveArchiveNow()
        wrapper.finish()
        listening.stop()
        server.stop()

        let again = VisorServer(port: UInt16(ServerTestCase.freePort()))
        defer { again.stop() }
        let back = try #require(again.session("survives"))
        #expect(back.driven && back.info.placement == .container)
        again.drivenProcess = { _ in DrivenProcess() }
        again.takeUpDrivenSessions()
        #expect(back.info.agentState == .starting && again.containerRunner.waiting.contains("survives"), "it waits for the engine")
        let engine = FakeContainer(shared: [sessions.path])
        again.sessionsContainer = engine
        let restarted = try #require(await eventually { engine.all.first })
        #expect(restarted.agent.agent != started.agent.agent, "a new agent")
        #expect(restarted.agent.resumeSessionID == "c-in-container", "on the conversation it had there")
        #expect(restarted.agent.workingDirectory == started.agent.workingDirectory)
        #expect(back.info.queued.first?.contains("The Visor server restarted while you were working") == true, "its cut-short turn picked up")
        #expect(again.placedInContainer == 1, "keeping the container up")
    }

    /// Check 7: Move Back hands its conversation back, into this
    /// computer's Claude folder for the folder it moves back to, and it
    /// carries on from it here.
    @Test func moveBackHandsItsConversationBack() async throws {
        let (started, wrapper, record) = try await placed("back")
        #expect(refusal(server.moveBack("back", resume: conversation, cwd: "", why: "moved back by request", loud: false)) == nil)
        #expect(await eventually { wrapper.got { if case .handBack = $0 { true } else { false } } ? true : nil } == true)
        let folder = started.agent.workingDirectory
        let key = ReturnedConversationIntake.runnerKey(for: folder)
        let transcript = #"{"type":"user","message":{"role":"user","content":"said in the container"}}"# + "\n"
        let parts: [AgentProtocol_V1_ReturnedConversation] = [
            .with { $0.header = .with {
                $0.agent = .with { $0.uuid = started.agent.agent }
                $0.harness = "claude"
                $0.workingDirectory = folder
                $0.sessionID = "c-in-container"
            } },
            .with { $0.file = .with { $0.place = "projects/\(key)/c-in-container.jsonl"; $0.data = Data(transcript.utf8); $0.last = true } },
        ]
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        let ack = try await withGRPCClient(transport: transport) { client in
            try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).returnConversation(metadata: bearer(started.agent.token),
                                                                                              requestProducer: { writer in
                for part in parts { try await writer.write(part) }
            })
        }
        #expect(ack.files == 1 && ack.sessionID == "c-in-container")
        #expect(await eventually { record.driven ? nil : true } == true, "back on this computer")
        #expect(record.info.placement == .host && record.move == nil)
        let here = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: record.info.cwd))
        let returned = try String(contentsOf: here.appendingPathComponent("c-in-container.jsonl"), encoding: .utf8)
        #expect(returned.contains("said in the container"))
        #expect(record.process.resumeID == "c-in-container" || record.notice?.contains("with its turns on the runner") == true)
        // Its agent there let go: ended if it doesn't by itself.
        #expect(await eventually { started.run.hasEnded ? true : nil } == true)
        wrapper.finish()
    }

    @Test func anAgentThatEndsIsStartedAgainAndThreeQuickEndsStopIt() async throws {
        let (first, wrapper, record) = try await placed("ends")
        wrapper.finish()
        first.run.end(0)
        let second = try #require(await eventually { self.container.all.count == 2 ? self.container.all[1] : nil })
        #expect(second.agent.agent != first.agent.agent && second.agent.resumeSessionID == "c-in-container")
        second.run.end(1)
        let third = try #require(await eventually { self.container.all.count == 3 ? self.container.all[2] : nil }, "after a pause")
        third.run.end(1)
        #expect(await eventually { record.info.agentState == .stopped ? true : nil } == true, "three quick ends stop it")
        #expect(record.notice?.contains("ended 3 times as it started") == true, "\(record.notice ?? "")")
        #expect(container.all.count == 3)
        #expect(record.driven, "it stays in the container")

        // Start Agent tries again.
        server.startAgent(record)
        #expect(await eventually { self.container.all.count == 4 ? true : nil } == true)
    }

    @Test func aContainerHeldStoppedStopsItsSessions() async throws {
        let (started, wrapper, record) = try await placed("held")
        container.standing.withLock { $0 = ContainerStatus(state: .stopped, enabled: true, canRun: true, since: 2, held: "it was stopped by hand") }
        wrapper.finish()
        started.run.end(137)
        #expect(await eventually { record.info.agentState == .stopped ? true : nil } == true)
        #expect(record.notice?.contains("as it was stopped by hand") == true, "\(record.notice ?? "")")
        #expect(container.all.count == 1, "not started again")
    }

    @Test func aContainerRestartStartsItsAgentAgainUncounted() async throws {
        let (started, wrapper, _) = try await placed("restart")
        // The container came back after the agent started: a restart.
        container.standing.withLock { $0 = ContainerStatus(state: .running, enabled: true, canRun: true, since: Date().timeIntervalSince1970 + 1) }
        wrapper.finish()
        started.run.end(137)
        let next = try #require(await eventually { self.container.all.count == 2 ? self.container.all[1] : nil })
        #expect(next.agent.resumeSessionID == "c-in-container")
        #expect(server.containerRunner.quickEnds["restart"] == 0, "not a quick end")
    }

    @Test func stopAgentLetsItGoAndStartAgentStartsANewOne() async throws {
        let (started, wrapper, record) = try await placed("stops")
        server.stopAgent(record)
        #expect(await eventually { wrapper.got { if case .stop = $0 { true } else { false } } ? true : nil } == true)
        #expect(record.info.agentState == .stopped && record.driven)
        // It doesn't end by itself: TERM after the grace.
        #expect(await eventually { started.run.signals.first == 15 ? true : nil } == true)
        #expect(container.all.count == 1, "its end starts nothing")
        #expect(server.placedInContainer == 0, "a stopped one doesn't keep the container up")
        wrapper.finish()
        server.startAgent(record)
        let next = try #require(await eventually { self.container.all.count == 2 ? self.container.all[1] : nil })
        #expect(next.agent.agent != started.agent.agent)
    }

    @Test func aMoveIsRefusedWhileTheContainerCantTakeSessions() async throws {
        let (record, agent) = try hostSession("off")
        container.standing.withLock { $0 = ContainerStatus(state: .off, enabled: false, canRun: true) }
        let result = await server.moveToContainer("off")
        #expect(refusal(result) == "The Sessions container is off: turn it on in Settings › Sessions Container.")
        #expect(!record.driven && !agent.ended && record.info.placement == .host)
        server.sessionsContainer = nil
        let none = await server.moveToContainer("off")
        #expect(refusal(none) == VisorServer.noContainerEngine)
    }

    @Test func aMoveWhoseAgentCantStartComesStraightBack() async throws {
        let (record, agent) = try hostSession("no-start")
        container.refusing.withLock { $0 = "no egress" }
        let result = await server.moveToContainer("no-start")
        let refused = try #require(refusal(result))
        #expect(refused.contains("no egress"))
        #expect(agent.ended, "its agent here had gone first")
        #expect(!record.driven && record.info.placement == .host, "back on this computer")
        #expect(record.notice?.contains("it couldn't start in the Sessions container: no egress") == true, "\(record.notice ?? "")")
    }

    @Test func aSessionOutsideTheSharedFoldersWorksInAFolderOfItsOwnThere() async throws {
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let record = SessionRecord(info: SessionInfo(id: "outside", agent: .claude, cwd: outside.path, title: "Outside", created: 0),
                                   process: HostAgent(conversation: conversation))
        server.sessions.append(record)
        _ = await server.moveToContainer("outside")
        let started = try #require(container.all.first)
        #expect(started.agent.workingDirectory == sessions.path + "/Claude/" + started.agent.agent)
        #expect(record.move?.cwd == outside.path, "where its conversation is here")
    }
}
}
