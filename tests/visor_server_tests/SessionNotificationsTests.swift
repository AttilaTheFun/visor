// What a session tells the person. Its notifications switched off, it
// pushes nothing but the widget's silent state; the switch is the
// session's, kept and sent with it. A turn of mail (another session's
// message, the inbox's notice) tells nothing when it ends, and neither it
// nor the agent's reply in it is the session's preview; the person's own
// message sent during it starts a turn of theirs that does, and an
// approval asked during it is told as any is.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

/// An agent that writes down what it is sent.
@MainActor
private final class QuietAgent: AgentProcess {
    let events: AsyncStream<AgentEvent>
    private let emit: AsyncStream<AgentEvent>.Continuation
    var skipPermissions = true
    var model: String?
    var effort: String?
    var approvalEnvironment: [String: String] = [:]
    var resumeID: String? { nil }
    var resumeCommand: String? { nil }
    var processID: Int32? { nil }
    var said: [String] = []

    init() { (events, emit) = AsyncStream.makeStream() }

    func send(_ text: String) throws { said.append(text) }
    func start() throws {}
    func startsTurn(_ text: String) -> Bool { true }
    func interrupt() { said.append("stop") }
    func stop() {}
    func end(within deadline: Duration) async {}
}

extension ServerTests {
@Suite @MainActor final class SessionNotificationsTests {
    private var server: VisorServer!
    /// The kinds pushed, and the states pushed silently, in order.
    private var said: [String] = []
    private var states: [String] = []

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-session-notifications-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7968)
        server.onPush = { [unowned self] _, _, _, kind in self.said.append(kind) }
        server.onStatusPush = { [unowned self] _, status in self.states.append(status) }
    }

    isolated deinit {
        server.stop()
    }

    private func record(_ id: String, _ title: String, agent: QuietAgent? = nil, busy: Bool = false) -> SessionRecord {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.busy = busy
        let record = SessionRecord(info: info, process: agent ?? QuietAgent(),
                                   entries: [TranscriptEntry(id: id + "-u1", role: .user, text: "Build it"),
                                             TranscriptEntry(id: id + "-a1", role: .assistant, text: "Built.")])
        record.noteLatest(at: 0)
        return record
    }

    /// `send_message` from `caller` to `target`, as its agent asks it.
    private func send(_ text: String, from caller: String, to target: String) {
        var e = Envelope(type: "agent")
        e.token = server.agentToken(for: caller)
        e.client = caller
        e.mode = "send"
        e.session = target
        e.text = text
        e.id = "r1"
        #expect(server.agentReply(e).error == nil)
    }

    private func approval(_ id: String) -> ApprovalRequest { ApprovalRequest(id: id, tool: "Bash", summary: "rm -rf build") }

    // MARK: The switch

    /// Off: no push for a turn finished, an approval waiting or a failure,
    /// but the widget's silent state still goes. On again: as before.
    @Test func testASessionSwitchedOffPushesOnlyItsState() {
        let session = record("s", "Halo", busy: true)
        server.sessions = [session]
        server.notifyPushes()
        server.perform(.notifications(session: "s", on: false), from: nil)
        #expect(session.info.notifications == false)

        _ = session.apply(.busy(false))
        server.notifyPushes()
        session.setPendingApproval(approval("a1"))
        server.notifyPushes()
        _ = session.apply(.failure("boom"))
        server.notifyPushes()
        #expect(said.isEmpty, "muted: neither the turn, the approval nor the failure")
        #expect(states == ["idle", "waiting"], "the widget still hears of each change of state")

        // On again: told as ever.
        server.perform(.notifications(session: "s", on: true), from: nil)
        session.setPendingApproval(nil)
        _ = session.apply(.busy(true))
        server.notifyPushes()
        _ = session.apply(.busy(false))
        server.notifyPushes()
        #expect(said == ["turn"])
        session.setPendingApproval(approval("a2"))
        server.notifyPushes()
        #expect(said == ["turn", "waiting"])
    }

    /// The switch is the session's: on unless switched off, in its info on
    /// the wire (absent is on), kept in the store, and switched over REST.
    @Test func testTheSwitchIsTheSessionsAndKept() throws {
        server.password = "pw"
        let session = record("s", "Halo")
        server.sessions = [session]
        #expect(session.info.notifications, "on by default")
        #expect(session.info.json["notifications"].bool == nil, "on is said by saying nothing")
        // A session from before the switch, or from an older server.
        let older = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"id":"o","title":"Old"}"#.utf8))
        #expect(older.notifications)
        #expect(older.turnOrigin == nil)

        let answer = server.route(HTTPRequest(method: "POST", path: "/api/sessions/s/notifications",
                                              headers: ["authorization": "Bearer pw"], body: #"{"on":false}"#))
        #expect(answer.status == 200)
        let reply = try #require(Envelope.decode(answer.body))
        #expect(reply.sessions?.first?.notifications == false, "the answer carries the session switched off")
        #expect(session.info.notifications == false)
        #expect(session.info.json["notifications"].bool == false)
        #expect(SessionInfo(json: session.info.json)?.notifications == false, "every client reads it")

        // Written down with the session, and read back.
        let stored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session.stored))
        #expect(stored.info.notifications == false)

        // The socket's envelope, on again.
        #expect(Envelope.decode(Envelope.notifications(session: "s", on: true).encoded())?.on == true)
        server.perform(.notifications(session: "s", on: true), from: nil)
        #expect(session.info.notifications)
    }

    // MARK: Turns of mail

    /// The inbox's notice starts a turn of mail: neither it nor the agent's
    /// reply in it pushes or becomes the preview; the unread count still
    /// moves.
    @Test func testAMailTurnAndItsReplyAreQuiet() {
        let agent = QuietAgent()
        let a = record("A", "Server work")
        let b = record("B", "Client work", agent: agent)
        server.sessions = [a, b]
        server.notifyPushes()
        #expect(b.info.preview == "Built.")

        send("Is the API done?", from: "A", to: "B")
        server.notifyPushes()
        let notice = "[Visor: you have 1 unread message in your inbox; read them with read_inbox]"
        #expect(agent.said == [notice], "the agent is told it has mail, in a turn of its own")
        #expect(b.info.turnOrigin == .mail)
        #expect(b.info.busy)
        #expect(b.info.unreadMail == 1, "the unread count moves")
        #expect(b.info.preview == "Built.", "the notice is not the preview")

        // Its rows, as the agent's log writes them.
        _ = b.take(fileRow: TranscriptEntry(id: "B-u2", role: .user, text: notice))
        _ = b.take(fileRow: TranscriptEntry(id: "B-a2", role: .assistant, text: "Told A the API is done."))
        #expect(b.info.preview == "Built.", "nor is the agent's reply to the mail")

        server.handle(.busy(false), from: b)
        #expect(said.isEmpty, "a turn of mail ending tells nothing")
        #expect(states == ["working", "idle"], "the widget still hears of it")
        #expect(b.info.turnOrigin == .mail, "the last turn's origin stays until the next")
    }

    /// An agent not yet reading its inbox is handed the message itself,
    /// headed with its sender: a turn of mail too.
    @Test func testAMessageHandedOverIsMailToo() {
        let agent = QuietAgent()
        let a = record("A", "Server work")
        let b = record("B", "Client work", agent: agent)
        b.takesMail = false
        server.sessions = [a, b]
        server.notifyPushes()
        send("Is the API done?", from: "A", to: "B")
        server.notifyPushes()
        #expect(agent.said.first?.hasPrefix("[Message from the Visor session “Server work” (A)") == true)
        #expect(b.info.turnOrigin == .mail)
        #expect(b.info.preview == "Built.")
        server.handle(.busy(false), from: b)
        #expect(said.isEmpty)
    }

    /// The person's message sent during a turn of mail waits, keeps its
    /// origin, and starts a turn of theirs once the mail's ends: that one
    /// is the preview, and tells.
    @Test func testThePersonsMessageDuringMailIsTheirs() throws {
        let agent = QuietAgent()
        let a = record("A", "Server work")
        let b = record("B", "Client work", agent: agent)
        server.sessions = [a, b]
        server.notifyPushes()
        send("Is the API done?", from: "A", to: "B")
        // The agent says its turn began, as it does once handed the words:
        // the turn stays the mail's.
        server.handle(.busy(true), from: b)
        #expect(b.info.turnOrigin == .mail)

        server.perform(.send(session: "B", text: "Ship it"), from: nil)
        #expect(b.info.queued == ["Ship it"], "it waits for the turn of mail")
        #expect(b.queuedOrigins == [.user])
        // Kept with the queue through a restart.
        let stored = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(b.stored))
        #expect(stored.queuedOrigins == [.user])

        server.handle(.busy(false), from: b)
        #expect(said.isEmpty, "the turn of mail ending tells nothing")
        #expect(agent.said.last == "Ship it")
        #expect(b.info.turnOrigin == .user)
        #expect(b.info.preview == "Ship it", "the person's own words are the preview at once")
        server.handle(.busy(true), from: b)
        #expect(b.info.turnOrigin == .user)

        _ = b.take(fileRow: TranscriptEntry(id: "B-u3", role: .user, text: "Ship it"))
        _ = b.take(fileRow: TranscriptEntry(id: "B-a3", role: .assistant, text: "Shipped."))
        #expect(b.info.preview == "Shipped.")
        server.handle(.busy(false), from: b)
        #expect(said == ["turn"], "the person's turn tells as ever")

        // And mail after it changes nothing the person sees.
        send("Thanks", from: "A", to: "B")
        server.handle(.busy(true), from: b)
        #expect(b.info.turnOrigin == .mail)
        server.handle(.busy(false), from: b)
        #expect(said == ["turn"])
        #expect(b.info.preview == "Shipped.")
    }

    /// An approval asked during a turn of mail is told as any is — unless
    /// the session's notifications are off.
    @Test func testAnApprovalDuringMailStillTells() {
        let a = record("A", "Server work")
        let b = record("B", "Client work")
        server.sessions = [a, b]
        server.notifyPushes()
        send("Run the migration", from: "A", to: "B")
        server.notifyPushes()
        #expect(b.info.turnOrigin == .mail)
        b.setPendingApproval(approval("a1"))
        server.notifyPushes()
        #expect(said == ["waiting"])

        b.setPendingApproval(nil)
        server.notifyPushes()
        server.perform(.notifications(session: "B", on: false), from: nil)
        b.setPendingApproval(approval("a2"))
        server.notifyPushes()
        #expect(said == ["waiting"], "switched off: not even an approval")
    }

    /// A turn the agent begins with nothing handed to it (a goal's next
    /// step, a loop waking) is the server's, and tells when it ends, even
    /// after a turn of mail.
    @Test func testATurnTheAgentBeganItselfIsTheSystems() {
        let a = record("A", "Server work")
        let b = record("B", "Client work")
        server.sessions = [a, b]
        server.notifyPushes()
        send("FYI", from: "A", to: "B")
        server.notifyPushes()
        server.handle(.busy(false), from: b)
        #expect(b.info.turnOrigin == .mail)
        server.handle(.busy(true), from: b)
        #expect(b.info.turnOrigin == .system)
        server.handle(.busy(false), from: b)
        #expect(said == ["turn"])
    }

    /// The server's restart nudge waits in the queue as the server's.
    @Test func testANudgeIsTheSystems() {
        let b = record("B", "Client work", busy: true)
        server.sessions = [b]
        b.enqueue(VisorServer.restartNudge, first: true, origin: .system)
        b.enqueue("[Visor: you have 2 unread messages in your inbox; read them with read_inbox]", origin: .mail)
        b.enqueue("And the tests?")
        #expect(b.queuedOrigins == [.system, .mail, .user])
        // A queue from before origins were kept: told by its words.
        #expect(SessionRecord.origin(of: VisorServer.restartNudge) == .system)
        #expect(SessionRecord.origin(of: "[Visor: you have 2 unread messages in your inbox; read them with read_inbox]") == .mail)
        #expect(SessionRecord.origin(of: "And the tests?") == .user)
        b.unqueue("[Visor: you have 2 unread messages in your inbox; read them with read_inbox]")
        #expect(b.queuedOrigins == [.system, .user])
    }

    // MARK: The preview

    /// The preview passes over every turn of mail, whatever form it came
    /// in, and a reply that is itself a message to another session; it
    /// keeps the reply to the server's own nudge.
    @Test func testThePreviewIsNeverMail() {
        let notice = "[Visor: you have 1 unread message in your inbox; read them with read_inbox]"
        let header = "[Message from the Visor session “Server work” (A) on mini (server s1), to this session “Client work” (B) on mini — "
            + "not from the user. To answer, use send_message with session A and server s1.]\n\nIs the API done?"
        let marked = AgentMessageMarkers.inboundText(from: "Server work", on: "mini", body: "Is the API done?")
        let mine = [TranscriptEntry(id: "u1", role: .user, text: "Build it"),
                    TranscriptEntry(id: "a1", role: .assistant, text: "Built.")]
        for mail in [notice, header, marked] {
            let rows = mine + [TranscriptEntry(id: "u2", role: .user, text: mail),
                               TranscriptEntry(id: "t2", role: .tool, text: "ok", toolName: "tool_result"),
                               TranscriptEntry(id: "a2", role: .assistant, text: "Answered A.")]
            #expect(SessionRecord.latestPreview(in: rows) == "Built.", "\(mail)")
            // Just begun: the mail's prompt alone.
            #expect(SessionRecord.latestPreview(in: mine + [rows[2]]) == "Built.")
            // The person's message after it is theirs.
            #expect(SessionRecord.latestPreview(in: rows + [TranscriptEntry(id: "u3", role: .user, text: "Ship it")]) == "Ship it")
        }
        // A reply to the person that is a message to another session.
        let sent = AgentMessageMarkers.outboundText(to: "Server work", on: "mini", body: "Done.")
        #expect(SessionRecord.latestPreview(in: [TranscriptEntry(id: "u1", role: .user, text: "Tell A"),
                                                 TranscriptEntry(id: "a1", role: .assistant, text: sent)]) == "Tell A")
        // The server's nudge is no word, its reply is.
        #expect(SessionRecord.latestPreview(in: mine + [TranscriptEntry(id: "u2", role: .user, text: VisorServer.resumeNudge),
                                                        TranscriptEntry(id: "a2", role: .assistant, text: "Picked it up.")]) == "Picked it up.")
        #expect(SessionRecord.latestPreview(in: mine + [TranscriptEntry(id: "u2", role: .user, text: VisorServer.resumeNudge)]) == "Built.")
    }

    /// The session's rules, as the server and every client read them.
    @Test func testWhatASessionTells() {
        var info = SessionInfo(id: "s", agent: .claude, cwd: "/tmp", title: "Halo", created: 0)
        #expect(info.tellsTurnEnd && info.tellsApprovals, "a session from before origins: the person's")
        info.turnOrigin = .mail
        #expect(!info.tellsTurnEnd)
        #expect(info.tellsApprovals)
        info.turnOrigin = .system
        #expect(info.tellsTurnEnd)
        info.notifications = false
        #expect(!info.tellsTurnEnd && !info.tellsApprovals)
        info.turnOrigin = .mail
        let back = SessionInfo(json: info.json)
        #expect(back?.turnOrigin == .mail)
        #expect(back?.notifications == false)
    }
}
}
