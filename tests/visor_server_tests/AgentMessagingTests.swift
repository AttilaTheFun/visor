// Sessions talking to each other: an agent holding this server's token
// lists the other sessions, messages one (marked as from it, queued while
// the other works) and reads what it said. Nobody else can.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class AgentMessagingTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-agent-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        // Never the real keychain.
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7996)
    }

    private func record(_ id: String, _ title: String, busy: Bool = false) -> SessionRecord {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.busy = busy
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                             entries: [TranscriptEntry(id: "u1", role: .user, text: "Build it"),
                                       TranscriptEntry(id: "a1", role: .assistant, text: "Built.")])
    }

    private func ask(_ mode: String, from caller: String, about target: String? = nil, text: String? = nil,
                     token: String? = nil) -> Envelope {
        var e = Envelope(type: "agent")
        e.token = token ?? server.agentToken
        e.client = caller
        e.mode = mode
        e.session = target
        e.text = text
        e.id = "r1"
        return server.agentReply(e)
    }

    /// The ask through the whole of what an agent's MCP server reaches.
    private func asked(_ mode: String, from caller: String, text: String? = nil, messageID: String? = nil,
                       version: String? = nil) async -> Envelope {
        var e = Envelope(type: "agent")
        e.token = server.agentToken
        e.client = caller
        e.mode = mode
        e.text = text
        e.messageID = messageID
        e.version = version
        e.id = "r1"
        return await withCheckedContinuation { done in server.answerAgent(e) { done.resume(returning: $0) } }
    }

    @Test func testAgentsListReadAndMessageEachOther() async throws {
        let a = record("A", "Server work")
        let b = record("B", "Client work", busy: true)
        server.sessions = [a, b]

        let list = ask("sessions", from: "A")
        #expect(list.id == "r1")
        #expect(list.error == nil)
        #expect(list.text?.contains("B — Client work") == true)
        #expect(!(list.text?.contains("A — ") == true), "a session is not offered itself")

        #expect(ask("read", from: "A", about: "B").text == "user: Build it\n\nassistant: Built.")

        // B is working: the message goes to its inbox, a copy to A's
        // outbox, and B is told it has mail when its turn ends, never the
        // words.
        let sent = ask("send", from: "A", about: "B", text: "Is the API done?")
        #expect(sent.error == nil)
        let id = try #require(sent.messageID)
        #expect(sent.text == ("Delivered to the inbox of “Client work” (B) on \(server.hostName), message id \(id): "
                       + "its agent is told it has mail when its turn ends."))
        #expect(b.info.queued == (["[Visor: you have 1 unread message in your inbox; read them with read_inbox]"]))
        #expect(b.mailbox.inbox.map(\.text) == ["Is the API done?"])
        #expect(a.mailbox.outbox.map(\.id) == [id])
        #expect(a.mailbox.outbox.map(\.state) == [.delivered])

        // A second message while the first notice waits: still one notice.
        _ = ask("send", from: "A", about: "B", text: "And the tests?")
        #expect(b.info.queued.count == 1, "one notice waits, whatever comes")
        #expect(b.mailbox.unread == 2)

        // B reads them, each headed with its sender, and how to answer:
        // never taken for the user's words or another session's.
        let inbox = await asked("inbox", from: "B")
        let text = try #require(inbox.text)
        #expect(text.contains("[Message from the Visor session “Server work” (A) on \(server.hostName) (server \(server.id)), "
                                    + "to this session “Client work” (B) on \(server.hostName) — not from the user. "
                                    + "To answer, use send_message with session A and server \(server.id).]\n\nIs the API done?"), Comment(rawValue: text))
        #expect(text.contains("And the tests?"), Comment(rawValue: text))
        #expect(text.contains("Message \(id), sent "), Comment(rawValue: text))
        #expect(b.mailbox.unread == 0)
        #expect(a.mailbox.outbox.map(\.state) == [.read, .read], "the sender sees it read")
        let again = await asked("inbox", from: "B")
        #expect(again.text == "No unread messages.")
        let everything = await asked("inbox", from: "B", text: "all")
        #expect(everything.text?.contains("Is the API done?") == true, "the read ones too")

        // Read before its turn: the notice that waited goes as nothing.
        #expect(b.takeNextQueued() == nil, "no notice for mail already read")

        // A's outbox, and message_status, from it.
        let outbox = await asked("outbox", from: "A")
        #expect(outbox.text?.contains("Message \(id) to “Client work” (B) on \(server.hostName)") == true, Comment(rawValue: outbox.text ?? ""))
        let status = await asked("status", from: "A", messageID: id)
        #expect(status.text == "Message \(id) to “Client work” (B) on \(server.hostName): read")
    }

    /// A notice that waited counts what is unread when its turn comes.
    @Test func testAWaitingNoticeCountsWhatIsUnreadWhenItsTurnComes() {
        let a = record("A", "Server work")
        let b = record("B", "Client work", busy: true)
        server.sessions = [a, b]
        _ = ask("send", from: "A", about: "B", text: "One")
        _ = ask("send", from: "A", about: "B", text: "Two")
        _ = ask("send", from: "A", about: "B", text: "Three")
        #expect((b.takeNextQueued()?.text) == "[Visor: you have 3 unread messages in your inbox; read them with read_inbox]")
    }

    /// An agent an earlier launch left running may have no read_inbox: it
    /// is handed the message as a turn, headed with its sender, until it
    /// asks something with the new MCP server.
    @Test func testAnAgentWithoutReadInboxIsHandedTheMessage() async {
        let a = record("A", "Server work")
        let b = record("B", "Client work", busy: true)
        b.takesMail = false
        server.sessions = [a, b]
        let sent = ask("send", from: "A", about: "B", text: "Is the API done?")
        #expect(sent.text == "Queued for “Client work” (B) on \(server.hostName): it is working and takes it when its turn ends.")
        #expect(b.info.queued.first?.hasPrefix("[Message from the Visor session “Server work” (A)") == true)
        #expect(b.info.queued.first?.hasSuffix("\n\nIs the API done?") == true)
        #expect(b.mailbox.inbox.isEmpty)
        #expect(a.mailbox.outbox.map(\.state) == [.delivered], "the sender keeps its copy all the same")

        // B's agent asks with the new MCP server: from now on, its inbox.
        _ = await asked("sessions", from: "B", version: "mail")
        #expect(b.takesMail)
        _ = ask("send", from: "A", about: "B", text: "And now?")
        #expect(b.mailbox.inbox.map(\.text) == ["And now?"])
    }

    private func mail(_ id: String) async -> HTTPResponse {
        let request = HTTPRequest(method: "GET", path: "/api/sessions/\(id)/mail", headers: ["authorization": "Bearer pw"], body: "")
        return await withCheckedContinuation { done in server.route(request) { done.resume(returning: $0) } }
    }

    /// A client reads a session's boxes (`GET /sessions/<id>/mail`), and
    /// its info says how many wait unread and when they changed.
    @Test func testAClientReadsTheBoxesAndTheUnreadCount() async throws {
        server.password = "pw"
        let a = record("A", "Server work")
        let b = record("B", "Client work")
        server.sessions = [a, b]
        #expect(b.info.unreadMail == 0)
        #expect(b.info.mailChanged == nil)
        _ = ask("send", from: "A", about: "B", text: "Look at this")
        #expect(b.info.unreadMail == 1)
        #expect(b.info.mailChanged != nil)
        #expect(a.info.mailChanged != nil, "the sender's outbox changed too")

        let answer = await mail("B")
        #expect(answer.status == 200)
        let boxes = try #require(Envelope.decode(answer.body))
        #expect(boxes.type == "mail")
        #expect((boxes.inbox?.map(\.text)) == ["Look at this"])
        #expect((boxes.inbox?.first?.from.sessionName) == "Server work")
        #expect((boxes.inbox?.first?.state) == .delivered)
        #expect(boxes.outbox == [])
        let outbox = await mail("A")
        let sent = try #require(Envelope.decode(outbox.body))
        #expect(sent.outbox == boxes.inbox, "one message at both ends")
        let none = await mail("Z")
        #expect(none.status == 404)

        // Its info carries the count to clients.
        let info = try #require(SessionInfo(json: b.info.json))
        #expect(info.unreadMail == 1)
        #expect(info.mailChanged == b.info.mailChanged)
    }

    /// The boxes are kept with the session, through a launch.
    @Test func testTheBoxesAreKeptWithTheSession() throws {
        let a = record("A", "Server work")
        let b = record("B", "Client work")
        server.sessions = [a, b]
        _ = ask("send", from: "A", about: "B", text: "Kept?")
        let stored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(b.stored))
        #expect(stored.mailbox == b.mailbox)
        #expect((stored.mailbox?.inbox.first?.text) == "Kept?")
        let old = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(StoredSession(info: b.info, entries: [], resumeID: nil, shape: nil)))
        #expect(old.mailbox == nil, "a session from before keeps none")
    }

    /// An agent under its host outlives the server that started it, and
    /// still holds the token it was given.
    @Test func testTheAgentsTokenOutlivesALaunch() {
        #expect(VisorServer(port: 7996).agentToken == server.agentToken)
    }

    @Test func testOnlyThisServersAgentsAndOnlyOthers() {
        server.sessions = [record("A", "One"), record("B", "Two")]
        #expect(ask("sessions", from: "A", token: "wrong").error != nil)
        #expect(ask("sessions", from: "Z").error != nil, "an unknown caller")
        #expect(ask("send", from: "A", about: "A", text: "hi").error != nil, "not itself")
        #expect(ask("send", from: "A", about: "B", text: "  ").error != nil, "not nothing")
    }
}
}
