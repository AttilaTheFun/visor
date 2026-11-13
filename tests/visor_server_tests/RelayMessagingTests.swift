// Agents on two servers talking through a client connected to both: the
// client reports to each what it is connected to, takes from one the
// messages its agents wrote for the other, carries each there and brings
// back what became of it. Two servers in one process, the client played
// by the test over their REST sides; neither learns the other's address
// or password.

@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class RelayMessagingTests {
    private var here: VisorServer!
    private var there: VisorServer!
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-relay-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("there"), withIntermediateDirectories: true)
        VisorServer.secrets = MemorySecrets()
        VisorServer.storeRoot = root
        here = VisorServer(port: ServerTestCase.freePort())
        here.password = "here-password"
        // Its own folder: a server of its own, with an id of its own. (The
        // folder is the process's: what either keeps from here on is kept
        // there, the outbox and the ledger in files of their own.)
        VisorServer.storeRoot = root.appendingPathComponent("there")
        there = VisorServer(port: ServerTestCase.freePort())
        there.password = "there-password"
        VisorServer.relaySendWait = 0.3
        VisorServer.relayReadWait = 0.3
    }

    isolated deinit {
        here.stop()
        there.stop()
        VisorServer.relaySendWait = 8
        VisorServer.relayReadWait = 20
    }

    private func record(_ id: String, _ title: String, busy: Bool = false) -> SessionRecord {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.busy = busy
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                             entries: [TranscriptEntry(id: "u1", role: .user, text: "Ship it")])
    }

    /// What a client connected to both says: both servers, with their sessions.
    private func report(client: String = "phone", servers: [VisorServer]? = nil, version: String? = nil) -> DirectoryReport {
        let servers = servers ?? [here!, there!]
        return DirectoryReport(client: client, clientName: "My iPhone", servers: servers.map { server in
            DirectoryServer(id: server.id, name: server === here ? "Mini" : "Laptop", version: version,
                            sessions: server.sessions.map { DirectorySession(id: $0.info.id, name: $0.displayName, agent: "Claude", busy: $0.info.busy) })
        })
    }

    private func post(_ server: VisorServer, _ path: String, _ body: Envelope) -> (status: Int, reply: Envelope?) {
        let password = server === here ? "here-password" : "there-password"
        let answer = server.route(HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer " + password], body: body.encoded()))
        return (answer.status, Envelope.decode(answer.body))
    }

    /// One exchange, as the client makes it: report to `source`, carry
    /// each message it answers with to `destination`, bring back the receipt.
    @discardableResult
    private func exchange(from source: VisorServer, to destination: VisorServer) -> [RelayReceipt] {
        var body = Envelope(type: "relay")
        body.report = report()
        let messages = post(source, "/api/relay", body).reply?.relayed ?? []
        return messages.compactMap { message in
            var carried = Envelope(type: "relay")
            carried.relayed = [message]
            guard let receipt = post(destination, "/api/relay/deliver", carried).reply?.receipt else { return nil }
            var back = Envelope(type: "relay")
            back.receipt = receipt
            #expect(post(source, "/api/relay/receipt", back).status == 200)
            return receipt
        }
    }

    private func ask(_ mode: String, about target: String? = nil, server: String? = nil, text: String? = nil,
                     messageID: String? = nil) async -> Envelope {
        var e = Envelope(type: "agent")
        e.token = here.agentToken
        e.client = "A"
        e.mode = mode
        e.session = target
        e.server = server
        e.text = text
        e.messageID = messageID
        e.id = "r1"
        return await withCheckedContinuation { done in here.answerAgent(e) { done.resume(returning: $0) } }
    }

    /// A session whose agent's last reply was `text`.
    private func writer(_ id: String, _ title: String, wrote text: String) -> SessionRecord {
        let sender = record(id, title)
        sender.entries.append(TranscriptEntry(id: "a1", role: .assistant, text: text))
        return sender
    }

    @Test func testAWrittenMessageToASessionHereIsHandedOverOnceAsATurnFromItsSender() {
        let sender = writer("A", "Mini work", wrote: AgentMessageMarkers.outboundText(to: "mini PLAN", on: here.hostName, body: "Ship it\ntoday"))
        here.sessions = [sender, record("P", "Mini plan", busy: true)]
        here.sendMarkedMessages(of: sender)
        here.sendMarkedMessages(of: sender)
        let queued = here.sessions[1].info.queued
        #expect(queued == [AgentMessageMarkers.inboundText(from: "Mini work", on: here.hostName, body: "Ship it\ntoday")], "once, however often the turn is looked at, and not into the inbox")
        #expect(here.sessions[1].mailbox.inbox.isEmpty)
        #expect(sender.mailbox.outbox.map(\.state) == [.delivered])
    }

    /// A native agent's row read from its file after its turn's end was
    /// heard, the next turn already begun: sent as it is read, once.
    @Test func testAWrittenMessageReadFromTheFileLateIsSentAsItArrives() {
        let sender = record("A", "Mini work")
        here.sessions = [sender, record("P", "Mini plan", busy: true)]
        let late = TranscriptEntry(id: "a9", role: .assistant,
                                   text: AgentMessageMarkers.outboundText(to: "Mini plan", on: here.hostName, body: "Late words"))
        sender.entries += [late, TranscriptEntry(id: "u2", role: .user, text: "The next turn")]
        here.sendMarkedMessages(of: sender)
        #expect(sender.mailbox.outbox.isEmpty, "the turn's end looks only at the turn")
        here.sendMarkedMessages(in: [late], of: sender)
        here.sendMarkedMessages(in: [late], of: sender)
        #expect(here.sessions[1].info.queued == [AgentMessageMarkers.inboundText(from: "Mini work", on: here.hostName, body: "Late words")])
        #expect(sender.mailbox.outbox.map(\.state) == [.delivered])
    }

    /// Mail sent with the inbox's tools to a session a runner's agent runs,
    /// which has no inbox to read: handed over as an `@@from` turn.
    @Test func testMailToASessionARunnerRunsIsATurn() {
        let sender = record("A", "Mini work")
        let moved = record("R", "Reviews", busy: true)
        moved.driven = true
        here.sessions = [sender, moved]
        let from = RelayEndpoint(server: here.id, serverName: here.hostName, session: "A", sessionName: "Mini work")
        _ = here.mail("Are you there?", from: from, to: moved, messageID: "m1", here: true)
        #expect(moved.mailbox.inbox.isEmpty)
        #expect(moved.info.queued == [AgentMessageMarkers.inboundText(from: "Mini work", on: here.hostName, body: "Are you there?")])
    }

    @Test func testASessionMovedToARunnerHasItsUnreadInboxHandedOverAsTurns() {
        let sender = record("A", "Mini work")
        let moved = record("R", "Reviews", busy: true)
        here.sessions = [sender, moved]
        let from = RelayEndpoint(server: here.id, serverName: here.hostName, session: "A", sessionName: "Mini work")
        let to = RelayEndpoint(server: here.id, serverName: here.hostName, session: "R", sessionName: "Reviews")
        for (id, text) in [("m1", "First"), ("m2", "Second")] {
            let message = MailMessage(id: id, from: from, to: to, text: text, sent: 1, state: .delivered, changed: 1)
            sender.mailbox.send(message)
            moved.mailbox.receive(message)
        }
        moved.info.queued = [Mailbox.notice(unread: 2)]
        moved.driven = true
        here.handOverInbox(moved)
        #expect(moved.mailbox.unread == 0)
        #expect(moved.info.queued == [AgentMessageMarkers.inboundText(from: "Mini work", on: here.hostName, body: "First"),
                                      AgentMessageMarkers.inboundText(from: "Mini work", on: here.hostName, body: "Second")],
                "no notice: the messages themselves, oldest first")
        #expect(sender.mailbox.outbox.map(\.state) == [.read, .read], "the sender learns they were read")
        // Later mail is a turn, and a notice never goes.
        here.notifyMail(moved)
        #expect(!moved.info.queued.contains(where: Mailbox.isNotice))
    }

    @Test func testAWrittenMessageToNoSessionHereFails() {
        let sender = writer("A", "Mini work", wrote: AgentMessageMarkers.outboundText(to: "Nobody", on: here.hostName, body: "Hello"))
        here.sessions = [sender]
        here.sendMarkedMessages(of: sender)
        #expect((sender.mailbox.outbox.first?.state) == .failed)
        #expect((sender.mailbox.outbox.first?.problem?.contains("Nobody")) == true)
    }

    @Test func testAWrittenMessageWaitsForAClientToNameItsComputerThenGoesAsATurn() {
        let sender = writer("A", "Mini work", wrote: AgentMessageMarkers.outboundText(to: "laptop work", on: "laptop", body: "Over to you"))
        here.sessions = [sender]
        there.sessions = [record("B", "Laptop work", busy: true)]
        here.sendMarkedMessages(of: sender)
        #expect((sender.mailbox.outbox.first?.state) == .waiting, "no client has named the laptop yet")
        let receipts = exchange(from: here, to: there)
        #expect(receipts.map(\.outcome) == [.queued])
        #expect((there.sessions[0].info.queued.count) == 1)
        let taken = there.sessions[0].info.queued.first.flatMap(AgentMessageMarkers.inbound)
        #expect(taken == AgentMessageMarkers.Addressed(session: "Mini work", computer: here.hostName, body: "Over to you"))
        #expect(there.sessions[0].mailbox.inbox.isEmpty, "a turn, not the inbox")
        #expect((sender.mailbox.outbox.first?.state) == .delivered)
        #expect((sender.mailbox.outbox.first?.to.server) == "", "the sender's copy keeps the names it was written with")
        #expect(exchange(from: here, to: there).isEmpty, "carried once")
    }

    @Test func testEachServerKnowsItsClientsBuildsAndTheOtherServers() async {
        here.sessions = [record("A", "Mini work")]
        var said = report()
        said.clientVersion = "0.31 (8)"
        said.clientPlatform = "iOS"
        said.servers[1].version = "0.31 (6)"
        here.takeReport(said)
        let list = await ask("sessions")
        #expect(list.text?.contains("On Laptop (server \(there.id), Visor Server 0.31 (6))") == true, Comment(rawValue: list.text ?? ""))
        #expect(list.text?.contains("My iPhone: Visor 0.31 (8) on iOS") == true, Comment(rawValue: list.text ?? ""))
        let answer = here.route(HTTPRequest(method: "GET", path: "/api/versions", headers: ["authorization": "Bearer here-password"], body: ""))
        #expect(answer.status == 200)
        let versions = parseJSON(answer.body)
        #expect((versions?["clients"][0]["version"].string) == "0.31 (8)")
        #expect((versions?["clients"][0]["platform"].string) == "iOS")
        #expect((versions?["servers"][0]["version"].string) == "0.31 (6)")
        #expect((versions?["server"]["id"].string) == here.id)
    }

    @Test func testAnAgentListsTheSessionsAClientReports() async {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work", busy: true)]
        let empty = await ask("sessions")
        #expect(!(empty.text?.contains("Laptop") == true), "nothing reported yet")

        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let list = await ask("sessions")
        let text = list.text ?? ""
        #expect(text.contains("On this computer, \(here.hostName) (server \(here.id)):\nNo other sessions."), Comment(rawValue: text))
        #expect(text.contains("On Laptop (server \(there.id)), as My iPhone reported"), Comment(rawValue: text))
        #expect(text.contains("B — Laptop work (Claude, working)"), Comment(rawValue: text))
        #expect(!text.contains("On Mini"), "this server is not listed as another")
    }

    @Test func testAMessageIsCarriedByAClientConnectedToBoth() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work", busy: true)]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())

        // The agent asks; while it waits, the client makes its round.
        let sent = Task { await ask("send", about: "B", text: "Is the client done?") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let receipts = exchange(from: here, to: there)
        #expect(receipts.map(\.outcome) == [.queued])
        let answer = await sent.value
        #expect(answer.error == nil)
        #expect(answer.text == "Queued for “Laptop work” (B) on Laptop: it is working and takes it when its turn ends.")

        // In B's inbox, and B told it has mail, never the words; A's
        // outbox knows it got there, by the same id.
        let b = try #require(there.sessions.first)
        #expect(b.info.queued == (["[Visor: you have 1 unread message in your inbox; read them with read_inbox]"]))
        let mail = try #require(b.mailbox.inbox.first)
        #expect(mail.text == "Is the client done?")
        #expect(mail.from == RelayEndpoint(server: here.id, serverName: here.hostName, session: "A", sessionName: "Mini work"))
        #expect((here.sessions.first?.mailbox.outbox.map(\.state)) == [.delivered])
        #expect((here.sessions.first?.mailbox.outbox.first?.id) == mail.id, "one id at both ends")
        #expect(exchange(from: here, to: there).isEmpty, "nothing left to carry")
    }

    /// Read on its server, a message is said read in its sender's outbox on
    /// the other: a read receipt carried back as any message is. Not to a
    /// server reported as older than 0.47, which knows no receipt.
    @Test func testAMessageReadThereIsReadInItsSendersOutbox() async throws {
        for (version, receipts) in [("0.47.1", [RelayReceipt.Outcome.sent]), ("0.46.17", [])] {
            here.sessions = [record("A", "Mini work")]
            there.sessions = [record("B", "Laptop work")]
            for server in [here!, there!] {
                _ = post(server, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(version: version); return e }())
            }
            let sent = Task { await ask("send", about: "B", text: "Read me") }
            try await Task.sleep(nanoseconds: 50_000_000)
            exchange(from: here, to: there)
            _ = await sent.value
            #expect((here.sessions.first?.mailbox.outbox.map(\.state)) == [.delivered], Comment(rawValue: version))

            var read = Envelope(type: "agent")
            read.token = there.agentToken
            read.client = "B"
            read.mode = "inbox"
            read.id = "r2"
            let inbox = await withCheckedContinuation { done in there.answerAgent(read) { done.resume(returning: $0) } }
            #expect(inbox.text?.contains("Read me") == true, Comment(rawValue: inbox.text ?? ""))

            var back = Envelope(type: "relay")
            back.report = report(version: version)
            let carried = post(there, "/api/relay", back).reply?.relayed ?? []
            #expect(carried.map(\.kind) == (receipts.isEmpty ? [] : [.receipt]), Comment(rawValue: version))
            for receipt in carried {
                var delivered = Envelope(type: "relay")
                delivered.relayed = [receipt]
                let taken = try #require(post(here, "/api/relay/deliver", delivered).reply?.receipt)
                #expect(taken.outcome == .sent)
                var answered = Envelope(type: "relay")
                answered.receipt = taken
                #expect(post(there, "/api/relay/receipt", answered).status == 200)
            }
            #expect((here.sessions.first?.mailbox.outbox.map(\.state)) == (receipts.isEmpty ? [.delivered] : [.read]), Comment(rawValue: version))
        }
    }

    @Test func testAServersVersionSaysWhetherItTakesReceipts() {
        #expect(VisorServer.knowsReceipts("0.47.0"))
        #expect(VisorServer.knowsReceipts("0.48.3"))
        #expect(VisorServer.knowsReceipts("1.0.0"))
        #expect(!VisorServer.knowsReceipts("0.46.17"))
        #expect(!VisorServer.knowsReceipts(nil))
        #expect(!VisorServer.knowsReceipts(""))
    }

    @Test func testACarriedMessageIsTakenOnceHoweverOftenItComes() throws {
        there.sessions = [record("B", "Laptop work", busy: true)]
        let now = Date().timeIntervalSince1970
        let message = RelayMessage(id: "m1", kind: .send, from: RelayEndpoint(server: here.id, serverName: "Mini", session: "A", sessionName: "Mini work"),
                                   to: RelayEndpoint(server: there.id, serverName: "Laptop", session: "B"), text: "Once",
                                   created: now, expires: now + 60)
        var carried = Envelope(type: "relay")
        carried.relayed = [message]
        let first = post(there, "/api/relay/deliver", carried).reply?.receipt
        let second = post(there, "/api/relay/deliver", carried).reply?.receipt
        #expect((first?.outcome) == .queued)
        #expect(second == first, "a second client carrying it is answered the same")
        #expect((there.sessions.first?.info.queued.count) == 1, "and it is not taken twice")
        // Kept across a restart.
        #expect((VisorServer.keptRelayLedger()["m1"]) != nil)
        // One for another server is refused, not failed.
        var stray = message
        stray.id = "m2"
        stray.to.server = "elsewhere"
        carried.relayed = [stray]
        #expect(post(there, "/api/relay/deliver", carried).status == 409)
    }

    @Test func testAReadIsCarriedAndAnswered() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let read = Task { await ask("read", about: "B", server: "Laptop") }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect((exchange(from: here, to: there).map(\.outcome)) == [.read])
        let answer = await read.value
        #expect(answer.text == "user: Ship it")
    }

    @Test func testAMessageNoClientCarriesWaitsAndIsAskedAfter() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let waiting = await ask("send", about: "B", text: "Later")
        #expect(waiting.error == nil)
        #expect(waiting.text?.hasPrefix("Waiting: no Visor client connected to both") == true, Comment(rawValue: waiting.text ?? ""))
        let id = try #require(waiting.messageID)
        #expect(waiting.text?.contains(id) == true)

        // Kept across a restart of the server it waits on.
        #expect((VisorServer.keptRelayOutbox()[id]?.status) == .waiting)

        // A client comes; the agent asks after it.
        exchange(from: here, to: there)
        let status = await ask("status", messageID: id)
        #expect(status.text == "Sent to “Laptop work” (B) on Laptop.")
        let unknown = await ask("status", messageID: "nope")
        #expect(unknown.error != nil)
    }

    @Test func testAMessageNotCarriedInADayExpires() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let waiting = await ask("send", about: "B", text: "Too late")
        let id = try #require(waiting.messageID)
        let message = try #require(here.relayOutbox[id]?.message)
        here.ageRelayOutbox(now: message.expires + 1)
        let status = await ask("status", messageID: id)
        #expect(status.error?.hasPrefix("Expired") == true, Comment(rawValue: status.error ?? ""))
        #expect(exchange(from: here, to: there).isEmpty, "an expired message is not handed out")
        // And the server it was for would not take it either.
        #expect((there.takeRelayed(message, now: message.expires + 1)?.outcome) == .failed)
    }

    @Test func testAServerIsNamedByIDOrByAName() async {
        here.sessions = [record("A", "Mini work")]
        let twin = DirectoryServer(id: "twin", name: "Laptop", sessions: [DirectorySession(id: "C", name: "Twin work")])
        var full = report()
        full.servers.append(twin)
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = full; return e }())

        let ambiguous = await ask("send", about: "B", server: "laptop", text: "Hi")
        #expect(ambiguous.error?.contains("Several computers are named laptop") == true, Comment(rawValue: ambiguous.error ?? ""))
        let unknown = await ask("send", about: "B", server: "Nowhere", text: "Hi")
        #expect(unknown.error?.contains("No computer Nowhere is known here") == true, Comment(rawValue: unknown.error ?? ""))
        let noSession = await ask("send", about: "Z", server: there.id, text: "Hi")
        #expect(noSession.error?.contains("No session Z on Laptop") == true, Comment(rawValue: noSession.error ?? ""))
        // Before ids: `<computer>/<id>`, the computer as a slug.
        let legacy = await ask("send", about: "twin/C", text: "Hi")
        #expect(legacy.error == nil)
        #expect((here.relayOutbox.values.first?.message.to.server) == "twin")
        // This server, by name: answered here.
        let local = await ask("read", about: "Q", server: here.hostName)
        #expect(local.error == "No other session with that id; list_sessions names them.")
    }

    @Test func testReportsAgeOut() {
        here.takeReport(report(), now: Date(timeIntervalSinceNow: -VisorServer.reportKept - 1))
        #expect(here.reportedServers().isEmpty)
        here.takeReport(report())
        #expect((here.reportedServers().map(\.server.id)) == [there.id])
        // A client that stopped taking part says it is connected to nothing.
        here.takeReport(DirectoryReport(client: "phone", clientName: "", servers: []))
        #expect(here.reportedServers().isEmpty)
    }

    /// The relay's envelopes, as JSON and as Codable, read back the same.
    @Test func testTheRelaysEnvelopesRoundTrip() throws {
        var e = Envelope(type: "relay")
        e.server = "laptop-id"
        e.messageID = "m1"
        e.report = report()
        e.relayed = [RelayMessage(id: "m1", kind: .read, from: RelayEndpoint(server: "a", serverName: "Mini", session: "A", sessionName: "Mini work"),
                                  to: RelayEndpoint(server: "b", serverName: "Laptop", session: "B"), text: "", rows: 5, created: 1, expires: 2)]
        e.receipt = RelayReceipt(message: "m1", outcome: .read, text: "user: Ship it")
        e.codes = ConnectionCodes(qr: "q", http: "h", ssh: "s")
        let read = try #require(Envelope.decode(e.encoded()))
        #expect(read.server == e.server)
        #expect(read.messageID == e.messageID)
        #expect(read.report == e.report)
        #expect(read.relayed == e.relayed)
        #expect(read.receipt == e.receipt)
        #expect(read.codes == e.codes)
        let coded = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(e))
        #expect(coded.relayed == e.relayed)
        #expect(coded.report == e.report)
    }

    @Test func testTheCodesAreTheMenuBarAppsAndAStrangerGetsNone() {
        here.settings.proxyEnabled = true
        here.settings.publicAddress = "https://mini.example.ts.net"
        let answer = here.route(HTTPRequest(method: "GET", path: "/api/codes", headers: ["authorization": "Bearer here-password"], body: ""))
        #expect(answer.status == 200)
        // The same codes as the menu bar's, read back (each encoding may
        // order the code's fields its own way).
        let codes = Envelope.decode(answer.body)?.codes
        let read = { (code: String?) in code.flatMap(ConnectionCode.init(parsing:)) }
        #expect(read(codes?.qr) != nil)
        #expect(read(codes?.qr) == here.connectionCode)
        #expect(read(codes?.https) == read(here.connectionCodes?.https))
        #expect((read(codes?.https)?.host) == "https://mini.example.ts.net")
        #expect((codes?.ssh) == nil)
        #expect((here.route(HTTPRequest(method: "GET", path: "/api/codes", headers: [:], body: "")).status) == 401)
    }
}
}
