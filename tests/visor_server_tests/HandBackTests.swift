// A moved session handed back by its runner's agent, over gRPC as its
// wrapper reaches the driver (agent_protocol's DriverMessage.hand_back and
// AgentDriver.ReturnConversation): a wrapper that said protocol 2 is asked
// to hand back rather than stop; its conversation, returned with its own
// token while its runner holds its claim, is put under this computer's key
// for the folder the session moves back to, and the session resumes on it
// here. Another agent's token, no token, a place outside the conversation,
// or a return nobody asked for is refused with nothing written; an older
// wrapper (protocol 1) is told to stop, and the session says its turns on
// the runner weren't returned.

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

/// A wrapper's driver stream: what it is sent.
private final class HandingBackWrapper: Sendable {
    let down = Mutex<[AgentProtocol_V1_DriverMessage]>([])
    private let upward: AsyncStream<AgentProtocol_V1_WrapperMessage>
    private let up: AsyncStream<AgentProtocol_V1_WrapperMessage>.Continuation

    init() {
        (upward, up) = AsyncStream.makeStream()
    }

    func connect(port: Int, token: String) {
        let upward = self.upward
        Task {
            let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
            try await withGRPCClient(transport: transport) { client in
                try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).connect(metadata: bearer(token), requestProducer: { writer in
                    for await message in upward { try await writer.write(message) }
                }, onResponse: { response in
                    for try await message in response.messages { self.down.withLock { $0.append(message) } }
                })
            }
        }
    }

    func send(_ message: AgentProtocol_V1_WrapperMessage) { up.yield(message) }

    func finish() { up.finish() }

    var handedBack: Bool {
        down.withLock { messages in messages.contains { message in if case .handBack = message.message { true } else { false } } }
    }

    var stopped: Bool {
        down.withLock { messages in messages.contains { message in if case .stop = message.message { true } else { false } } }
    }
}

/// What a call shows: `token` as a bearer, or nothing.
private func bearer(_ token: String?) -> Metadata {
    var metadata = Metadata()
    if let token { metadata.addString("Bearer \(token)", forKey: "authorization") }
    return metadata
}

/// Whether the server took it.
private func took(_ result: Result<Void, AgentJobRefusal>) -> Bool {
    if case .success = result { return true }
    return false
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
@Suite(.serialized) @MainActor final class HandBackTests {
    private var server: VisorServer!
    private var listening: VisorDriver.Listening!
    private var root: URL!
    private var savedHome: URL!
    private let port = Int(ServerTestCase.freePort())
    private let before = "11111111-2222-4333-8444-555555555555"
    private let onRunner = "0b6c2d1e-8f3a-4c5b-9d7e-1a2b3c4d5e6f"

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-hand-back-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedHome = ClaudeSessionFiles.home
        ClaudeSessionFiles.home = root.appendingPathComponent("home", isDirectory: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: UInt16(ServerTestCase.freePort()))
        listening = VisorDriver.Listening(host: "127.0.0.1", port: port, url: "http://127.0.0.1:\(port)", harness: "echo")
        listening.serve(server)
        for _ in 0..<200 {
            do {
                _ = try await dispatcher { try await $0.claim(.with { $0.runner = "Warm"; $0.capabilities = ["none"] }) }
                break
            } catch {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    isolated deinit {
        listening.stop()
        server.stop()
        ClaudeSessionFiles.home = savedHome
        try? FileManager.default.removeItem(at: root)
    }

    private var jobs: JobQueue { listening.jobs! }

    private func dispatcher<T: Sendable>(_ body: @escaping @Sendable (AgentProtocol_V1_AgentDispatcher.Client<HTTP2ClientTransport.Posix>) async throws -> T)
        async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        return try await withGRPCClient(transport: transport) { client in
            try await body(AgentProtocol_V1_AgentDispatcher.Client(wrapping: client))
        }
    }

    private func claimed() async throws -> AgentProtocol_V1_Job? {
        let answer = try await dispatcher { try await $0.claim(.with { $0.runner = "Test"; $0.capabilities = ["native", "harness:echo"] }) }
        return answer.hasJob ? answer.job : nil
    }

    /// Where the runner's agent works, as its wrapper says.
    private func runnerFolder(_ agent: String) -> String { "/Volumes/Sessions/Claude/" + agent }

    /// The session `id`, moved to a runner whose agent dialled in as a
    /// wrapper of protocol `version`, its claim held: its job, its stream,
    /// its record, and the folder it moves back to here.
    private func moved(_ id: String, version: Int32 = 2) async throws -> (AgentProtocol_V1_Job, HandingBackWrapper, SessionRecord, String) {
        let here = root.appendingPathComponent("here-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        let agent = UUID().uuidString.lowercased()
        let record = server.takeDriven(SessionInfo(id: id, agent: .claude, cwd: here.path, title: "Moved", created: 0), process: DrivenProcess())
        let move = AgentJobMove(agent: agent, session: id, title: "Moved", resume: before, cwd: here.path, runsOn: "native")
        record.move = move
        #expect(jobs.queueResume(move) == .success(id))
        let job = try #require(try await claimed())
        let wrapper = HandingBackWrapper()
        wrapper.connect(port: port, token: job.token)
        let folder = runnerFolder(agent)
        wrapper.send(.with { $0.hello = .with {
            $0.protocol = version
            $0.agent = .with { $0.uuid = agent; $0.dispatcherURL = "http://127.0.0.1" }
            $0.spec = .with { $0.harness = "echo"; $0.title = "Moved"; $0.workingDirectory = folder }
            $0.hostName = "runner"
        } })
        let process = try #require(await eventually { (record.process as? DrivenProcess).flatMap { $0.wrapperProtocol == version ? $0 : nil } })
        #expect(process.takesHandBack == (version >= 2))
        #expect(record.info.cwd == folder, "working on the runner")
        return (job, wrapper, record, here.path)
    }

    /// The returned conversation's messages: its header, then each file whole.
    private func conversation(of agent: String, folder: String, session: String,
                              _ files: [(String, String)]) -> [AgentProtocol_V1_ReturnedConversation] {
        let header = AgentProtocol_V1_ReturnedConversation.with { $0.header = .with {
            $0.agent = .with { $0.uuid = agent; $0.dispatcherURL = "http://127.0.0.1" }
            $0.harness = "claude"
            $0.workingDirectory = folder
            $0.sessionID = session
        } }
        let key = ReturnedConversationIntake.runnerKey(for: folder)
        return [header] + files.map { place, text in
            .with { $0.file = .with { $0.place = "projects/\(key)/\(place)"; $0.data = Data(text.utf8); $0.last = true } }
        }
    }

    /// ReturnConversation, showing `token`: its answer, or how it was refused.
    private func returnConversation(_ parts: [AgentProtocol_V1_ReturnedConversation], token: String?)
        async -> (ack: AgentProtocol_V1_ReturnedConversationAck?, code: RPCError.Code?) {
        do {
            let transport = try HTTP2ClientTransport.Posix(target: .dns(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
            let ack = try await withGRPCClient(transport: transport) { client in
                try await AgentProtocol_V1_AgentDriver.Client(wrapping: client).returnConversation(metadata: bearer(token), requestProducer: { writer in
                    for part in parts { try await writer.write(part) }
                })
            }
            return (ack, nil)
        } catch {
            return (nil, (error as? RPCError)?.code ?? .unknown)
        }
    }

    private var projects: URL { ClaudeSessionFiles.projectsRoot() }

    /// Every file under Claude's projects here.
    private var written: [String] {
        let all = FileManager.default.subpaths(atPath: projects.path) ?? []
        return all.filter { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: projects.appendingPathComponent(path).path, isDirectory: &folder) && !folder.boolValue
        }.sorted()
    }

    @Test func aProtocolTwoWrapperHandsBackAndTheSessionResumesTheReturnedConversation() async throws {
        let (job, wrapper, record, here) = try await moved("h1")
        #expect(took(server.moveBack("h1", resume: before, cwd: here, why: "moved back by request")))
        #expect(await eventually { wrapper.handedBack ? true : nil } == true, "asked to hand back")
        #expect(!wrapper.stopped, "not told to stop")
        #expect(record.driven && server.isHandingBack("h1"))

        let folder = runnerFolder(job.agent.uuid)
        let answer = await returnConversation(conversation(of: job.agent.uuid, folder: folder, session: onRunner, [
            ("\(onRunner).jsonl", "{\"said\":\"the word is heliotrope\"}\n"),
            ("\(onRunner)/subagents/agent-a.jsonl", "{}\n"),
            ("memory/MEMORY.md", "- heliotrope\n"),
        ]), token: job.token)
        #expect(answer.code == nil)
        #expect(answer.ack?.files == 3 && answer.ack?.sessionID == onRunner)
        await server.handBackEnded("h1")

        let key = ClaudeSessionFiles.projectDirectoryName(for: here)
        #expect(written == ["\(key)/\(onRunner).jsonl", "\(key)/\(onRunner)/subagents/agent-a.jsonl", "\(key)/memory/MEMORY.md"],
                "re-keyed for the folder it moves back to, and nothing else")
        #expect(!record.driven && !server.isHandingBack("h1"))
        #expect(record.info.cwd == here)
        #expect(record.process.resumeID == onRunner, "resumed natively on the returned conversation")
        #expect(record.notice?.hasPrefix("Back on this computer, with its turns on the runner: moved back by request (") == true, "\(record.notice ?? "")")
        #expect(!jobs.holds(job.agent.uuid), "its job let go")
        wrapper.finish()
    }

    @Test func aReturnWithoutItsAgentsTokenOrForAnotherAgentIsRefused() async throws {
        let (job, wrapper, record, here) = try await moved("h2")
        _ = try jobs.queueStart({ var e = Envelope(type: "job"); e.agent = .claude; e.title = "Other"; e.cwd = "/tmp"; return e }()).get()
        let other = try #require(try await claimed())
        #expect(took(server.moveBack("h2", resume: before, cwd: here, why: "moved back by request")))
        #expect(await eventually { wrapper.handedBack ? true : nil } == true)
        let folder = runnerFolder(job.agent.uuid)
        let parts = conversation(of: job.agent.uuid, folder: folder, session: onRunner, [("\(onRunner).jsonl", "{}\n")])

        #expect(await returnConversation(parts, token: nil).code == .unauthenticated, "no token")
        #expect(await returnConversation(parts, token: "not-a-token").code == .unauthenticated)
        #expect(await returnConversation(parts, token: other.token).code == .unauthenticated, "another agent's valid token, as this agent")
        // Another agent's own, as itself: its session isn't moving back.
        let theirs = conversation(of: other.agent.uuid, folder: folder, session: onRunner, [("\(onRunner).jsonl", "{}\n")])
        #expect(await returnConversation(theirs, token: other.token).code == .failedPrecondition)
        #expect(written.isEmpty, "nothing written")
        #expect(record.driven && server.isHandingBack("h2"), "still waiting for its own agent's")

        // Its own token, but a place outside the conversation: refused,
        // nothing written, and the session back without it.
        let escaping = conversation(of: job.agent.uuid, folder: folder, session: onRunner, [
            ("\(onRunner).jsonl", "{}\n"),
            ("../../settings.json", "{\"permissions\":{}}"),
        ])
        #expect(await returnConversation(escaping, token: job.token).code == .invalidArgument)
        await server.handBackEnded("h2")
        #expect(written.isEmpty, "nothing written, its transcript staged before it included")
        #expect(!record.driven)
        #expect(record.process.resumeID == before, "on the conversation it had before it moved")
        #expect(record.notice?.contains("Its turns on the runner weren't returned (it would put a file at") == true, "\(record.notice ?? "")")
        // Once back, a late return is refused too.
        #expect(await returnConversation(parts, token: job.token).code != nil)
        #expect(written.isEmpty)
        wrapper.finish()
    }

    @Test func aReturnNobodyAskedForIsRefused() async throws {
        let (job, wrapper, record, _) = try await moved("h3")
        let parts = conversation(of: job.agent.uuid, folder: runnerFolder(job.agent.uuid), session: onRunner, [("\(onRunner).jsonl", "{}\n")])
        #expect(await returnConversation(parts, token: job.token).code == .failedPrecondition)
        #expect(written.isEmpty && record.driven)
        wrapper.finish()
    }

    @Test func aProtocolOneWrapperIsToldToStopAndTheSessionSaysItsTurnsWerentReturned() async throws {
        let (_, wrapper, record, here) = try await moved("h4", version: 1)
        #expect(took(server.moveBack("h4", resume: before, cwd: here, why: "moved back by request")))
        #expect(await eventually { wrapper.stopped ? true : nil } == true, "told to stop")
        #expect(!wrapper.handedBack)
        #expect(!record.driven && !server.isHandingBack("h4"), "back at once")
        #expect(record.process.resumeID == before)
        #expect(record.notice?.contains("Its turns on the runner weren't returned (its runner's agent can't return its conversation)") == true)
        wrapper.finish()
    }
}
}
