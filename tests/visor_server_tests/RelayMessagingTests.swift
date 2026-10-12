// Agents on two servers talking through a client connected to both: the
// client reports to each what it is connected to, takes from one the
// messages its agents wrote for the other, carries each there and brings
// back what became of it. Two servers in one process, the client played
// by the test over their REST sides; neither learns the other's address
// or password.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class RelayMessagingTests: ServerTestCase {
    private var here: VisorServer!
    private var there: VisorServer!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-relay-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("there"), withIntermediateDirectories: true)
        VisorServer.secrets = MemorySecrets()
        VisorServer.storeRoot = root
        here = VisorServer(port: 7980)
        here.password = "here-password"
        // Its own folder: a server of its own, with an id of its own. (The
        // folder is the process's: what either keeps from here on is kept
        // there, the outbox and the ledger in files of their own.)
        VisorServer.storeRoot = root.appendingPathComponent("there")
        there = VisorServer(port: 7982)
        there.password = "there-password"
        VisorServer.relaySendWait = 0.3
        VisorServer.relayReadWait = 0.3
    }

    override func tearDown() async throws {
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
    private func report(client: String = "phone", servers: [VisorServer]? = nil) -> DirectoryReport {
        let servers = servers ?? [here!, there!]
        return DirectoryReport(client: client, clientName: "Logan's iPhone", servers: servers.map { server in
            DirectoryServer(id: server.id, name: server === here ? "Mini" : "Laptop",
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
            XCTAssertEqual(post(source, "/api/relay/receipt", back).status, 200)
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

    func testAnAgentListsTheSessionsAClientReports() async {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work", busy: true)]
        let empty = await ask("sessions")
        XCTAssertFalse(empty.text?.contains("Laptop") == true, "nothing reported yet")

        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let list = await ask("sessions")
        let text = list.text ?? ""
        XCTAssertTrue(text.contains("On this computer, \(here.hostName) (server \(here.id)):\nNo other sessions."), text)
        XCTAssertTrue(text.contains("On Laptop (server \(there.id)), as Logan's iPhone reported"), text)
        XCTAssertTrue(text.contains("B — Laptop work (Claude, working)"), text)
        XCTAssertFalse(text.contains("On Mini"), "this server is not listed as another")
    }

    func testAMessageIsCarriedByAClientConnectedToBoth() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work", busy: true)]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())

        // The agent asks; while it waits, the client makes its round.
        let sent = Task { await ask("send", about: "B", text: "Is the client done?") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let receipts = exchange(from: here, to: there)
        XCTAssertEqual(receipts.map(\.outcome), [.queued])
        let answer = await sent.value
        XCTAssertNil(answer.error)
        XCTAssertEqual(answer.text, "Queued for “Laptop work” (B) on Laptop: it is working and takes it when its turn ends.")

        let queued = try XCTUnwrap(there.sessions.first?.info.queued.first)
        XCTAssertTrue(queued.contains("“Mini work” (A) on \(here.hostName)"), queued)
        XCTAssertTrue(queued.contains("send_message with session A and server \(here.id)"), queued)
        XCTAssertTrue(queued.hasSuffix("Is the client done?"))
        XCTAssertTrue(exchange(from: here, to: there).isEmpty, "nothing left to carry")
    }

    func testACarriedMessageIsTakenOnceHoweverOftenItComes() throws {
        there.sessions = [record("B", "Laptop work", busy: true)]
        let now = Date().timeIntervalSince1970
        let message = RelayMessage(id: "m1", kind: .send, from: RelayEndpoint(server: here.id, serverName: "Mini", session: "A", sessionName: "Mini work"),
                                   to: RelayEndpoint(server: there.id, serverName: "Laptop", session: "B"), text: "Once",
                                   created: now, expires: now + 60)
        var carried = Envelope(type: "relay")
        carried.relayed = [message]
        let first = post(there, "/api/relay/deliver", carried).reply?.receipt
        let second = post(there, "/api/relay/deliver", carried).reply?.receipt
        XCTAssertEqual(first?.outcome, .queued)
        XCTAssertEqual(second, first, "a second client carrying it is answered the same")
        XCTAssertEqual(there.sessions.first?.info.queued.count, 1, "and it is not taken twice")
        // Kept across a restart.
        XCTAssertNotNil(VisorServer.keptRelayLedger()["m1"])
        // One for another server is refused, not failed.
        var stray = message
        stray.id = "m2"
        stray.to.server = "elsewhere"
        carried.relayed = [stray]
        XCTAssertEqual(post(there, "/api/relay/deliver", carried).status, 409)
    }

    func testAReadIsCarriedAndAnswered() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let read = Task { await ask("read", about: "B", server: "Laptop") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(exchange(from: here, to: there).map(\.outcome), [.read])
        let answer = await read.value
        XCTAssertEqual(answer.text, "user: Ship it")
    }

    func testAMessageNoClientCarriesWaitsAndIsAskedAfter() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let waiting = await ask("send", about: "B", text: "Later")
        XCTAssertNil(waiting.error)
        XCTAssertTrue(waiting.text?.hasPrefix("Waiting: no Visor client connected to both") == true, waiting.text ?? "")
        let id = try XCTUnwrap(waiting.messageID)
        XCTAssertTrue(waiting.text?.contains(id) == true)

        // Kept across a restart of the server it waits on.
        XCTAssertEqual(VisorServer.keptRelayOutbox()[id]?.status, .waiting)

        // A client comes; the agent asks after it.
        exchange(from: here, to: there)
        let status = await ask("status", messageID: id)
        XCTAssertEqual(status.text, "Sent to “Laptop work” (B) on Laptop.")
        let unknown = await ask("status", messageID: "nope")
        XCTAssertNotNil(unknown.error)
    }

    func testAMessageNotCarriedInADayExpires() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work")]
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = report(); return e }())
        let waiting = await ask("send", about: "B", text: "Too late")
        let id = try XCTUnwrap(waiting.messageID)
        let message = try XCTUnwrap(here.relayOutbox[id]?.message)
        here.ageRelayOutbox(now: message.expires + 1)
        let status = await ask("status", messageID: id)
        XCTAssertTrue(status.error?.hasPrefix("Expired") == true, status.error ?? "")
        XCTAssertTrue(exchange(from: here, to: there).isEmpty, "an expired message is not handed out")
        // And the server it was for would not take it either.
        XCTAssertEqual(there.takeRelayed(message, now: message.expires + 1)?.outcome, .failed)
    }

    func testAServerIsNamedByIDOrByAName() async {
        here.sessions = [record("A", "Mini work")]
        let twin = DirectoryServer(id: "twin", name: "Laptop", sessions: [DirectorySession(id: "C", name: "Twin work")])
        var full = report()
        full.servers.append(twin)
        _ = post(here, "/api/relay", { var e = Envelope(type: "relay"); e.report = full; return e }())

        let ambiguous = await ask("send", about: "B", server: "laptop", text: "Hi")
        XCTAssertTrue(ambiguous.error?.contains("Several computers are named laptop") == true, ambiguous.error ?? "")
        let unknown = await ask("send", about: "B", server: "Nowhere", text: "Hi")
        XCTAssertTrue(unknown.error?.contains("No computer Nowhere is known here") == true, unknown.error ?? "")
        let noSession = await ask("send", about: "Z", server: there.id, text: "Hi")
        XCTAssertTrue(noSession.error?.contains("No session Z on Laptop") == true, noSession.error ?? "")
        // Before ids: `<computer>/<id>`, the computer as a slug.
        let legacy = await ask("send", about: "twin/C", text: "Hi")
        XCTAssertNil(legacy.error)
        XCTAssertEqual(here.relayOutbox.values.first?.message.to.server, "twin")
        // This server, by name: answered here.
        let local = await ask("read", about: "Q", server: here.hostName)
        XCTAssertEqual(local.error, "No other session with that id; list_sessions names them.")
    }

    func testReportsAgeOut() {
        here.takeReport(report(), now: Date(timeIntervalSinceNow: -VisorServer.reportKept - 1))
        XCTAssertTrue(here.reportedServers().isEmpty)
        here.takeReport(report())
        XCTAssertEqual(here.reportedServers().map(\.server.id), [there.id])
        // A client that stopped taking part says it is connected to nothing.
        here.takeReport(DirectoryReport(client: "phone", clientName: "", servers: []))
        XCTAssertTrue(here.reportedServers().isEmpty)
    }

    /// The relay's envelopes, as JSON and as Codable, read back the same.
    func testTheRelaysEnvelopesRoundTrip() throws {
        var e = Envelope(type: "relay")
        e.server = "laptop-id"
        e.messageID = "m1"
        e.report = report()
        e.relayed = [RelayMessage(id: "m1", kind: .read, from: RelayEndpoint(server: "a", serverName: "Mini", session: "A", sessionName: "Mini work"),
                                  to: RelayEndpoint(server: "b", serverName: "Laptop", session: "B"), text: "", rows: 5, created: 1, expires: 2)]
        e.receipt = RelayReceipt(message: "m1", outcome: .read, text: "user: Ship it")
        e.codes = ConnectionCodes(qr: "q", http: "h", ssh: "s")
        let read = try XCTUnwrap(Envelope.decode(e.encoded()))
        XCTAssertEqual(read.server, e.server)
        XCTAssertEqual(read.messageID, e.messageID)
        XCTAssertEqual(read.report, e.report)
        XCTAssertEqual(read.relayed, e.relayed)
        XCTAssertEqual(read.receipt, e.receipt)
        XCTAssertEqual(read.codes, e.codes)
        let coded = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(coded.relayed, e.relayed)
        XCTAssertEqual(coded.report, e.report)
    }

    func testTheCodesAreTheMenuBarAppsAndAStrangerGetsNone() {
        here.settings.proxyEnabled = true
        here.settings.publicAddress = "https://mini.example.ts.net"
        let answer = here.route(HTTPRequest(method: "GET", path: "/api/codes", headers: ["authorization": "Bearer here-password"], body: ""))
        XCTAssertEqual(answer.status, 200)
        // The same codes as the menu bar's, read back (each encoding may
        // order the code's fields its own way).
        let codes = Envelope.decode(answer.body)?.codes
        let read = { (code: String?) in code.flatMap(ConnectionCode.init(parsing:)) }
        XCTAssertNotNil(read(codes?.qr))
        XCTAssertEqual(read(codes?.qr), here.connectionCode)
        XCTAssertEqual(read(codes?.https), read(here.connectionCodes?.https))
        XCTAssertEqual(read(codes?.https)?.host, "https://mini.example.ts.net")
        XCTAssertNil(codes?.ssh)
        XCTAssertEqual(here.route(HTTPRequest(method: "GET", path: "/api/codes", headers: [:], body: "")).status, 401)
    }
}
