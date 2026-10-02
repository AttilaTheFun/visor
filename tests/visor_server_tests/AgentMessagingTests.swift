// Sessions talking to each other: an agent holding this server's token
// lists the other sessions, messages one (marked as from it, queued while
// the other works) and reads what it said. Nobody else can.

import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class AgentMessagingTests: XCTestCase {
    private var server: VisorServer!

    override func setUp() async throws {
        try await super.setUp()
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

    func testAgentsListReadAndMessageEachOther() {
        let a = record("A", "Server work")
        let b = record("B", "Client work", busy: true)
        server.sessions = [a, b]

        let list = ask("sessions", from: "A")
        XCTAssertEqual(list.id, "r1")
        XCTAssertNil(list.error)
        XCTAssertTrue(list.text?.contains("B — Client work") == true)
        XCTAssertFalse(list.text?.contains("A — ") == true, "a session is not offered itself")

        XCTAssertEqual(ask("read", from: "A", about: "B").text, "user: Build it\n\nassistant: Built.")

        // B is working: the message waits for its turn, marked as A's.
        let sent = ask("send", from: "A", about: "B", text: "Is the API done?")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.text?.hasPrefix("Queued") == true)
        XCTAssertEqual(b.info.queued.count, 1)
        XCTAssertTrue(b.info.queued[0].contains("Visor session “Server work” (A)"))
        XCTAssertTrue(b.info.queued[0].hasSuffix("Is the API done?"))
    }

    func testOnlyThisServersAgentsAndOnlyOthers() {
        server.sessions = [record("A", "One"), record("B", "Two")]
        XCTAssertNotNil(ask("sessions", from: "A", token: "wrong").error)
        XCTAssertNotNil(ask("sessions", from: "Z").error, "an unknown caller")
        XCTAssertNotNil(ask("send", from: "A", about: "A", text: "hi").error, "not itself")
        XCTAssertNotNil(ask("send", from: "A", about: "B", text: "  ").error, "not nothing")
    }
}

/// Sessions on linked computers: two servers, each with its own REST side
/// on this Mac, linked by a code whose host is the other's base address.
@MainActor
final class LinkedMessagingTests: XCTestCase {
    private var here: VisorServer!
    private var there: VisorServer!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-link-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        here = VisorServer(port: 7980)
        there = VisorServer(port: 7982)
        here.exposure = FakeExposure()
        let road = FakeExposure()
        road.name = "other-mac.example.ts.net"
        there.exposure = road
        there.password = "there-password"
    }

    override func tearDown() async throws {
        here.stop()
        there.stop()
        try await super.tearDown()
    }

    private func record(_ id: String, _ title: String, busy: Bool = false) -> SessionRecord {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.busy = busy
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil),
                             entries: [TranscriptEntry(id: "u1", role: .user, text: "Ship it")])
    }

    private func ask(_ mode: String, about target: String? = nil, text: String? = nil) async -> Envelope {
        var e = Envelope(type: "agent")
        e.token = here.agentToken
        e.client = "A"
        e.mode = mode
        e.session = target
        e.text = text
        e.id = "r1"
        return await withCheckedContinuation { done in here.answerAgent(e) { done.resume(returning: $0) } }
    }

    func testAgentsReachSessionsOnALinkedComputer() async throws {
        here.sessions = [record("A", "Mini work")]
        there.sessions = [record("B", "Laptop work", busy: true)]
        for _ in 0..<50 where !there.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        here.adopt(ConnectionCode(name: "Other Mac", host: "http://127.0.0.1:\(there.apiPort)", password: "there-password"))

        let list = await ask("sessions")
        XCTAssertTrue(list.text?.contains("On this computer: none.") == true, list.text ?? "")
        XCTAssertTrue(list.text?.contains("other-mac/B — Laptop work") == true, list.text ?? "")

        let read = await ask("read", about: "other-mac/B")
        XCTAssertEqual(read.text, "user: Ship it")

        let sent = await ask("send", about: "other-mac/B", text: "Is the client done?")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.text?.hasPrefix("Queued") == true)
        let queued = try XCTUnwrap(there.sessions.first?.info.queued.first)
        XCTAssertTrue(queued.contains("“Mini work” (\(here.slug)/A) on \(here.hostName)"), queued)
        XCTAssertTrue(queued.hasSuffix("Is the client done?"))

        let nowhere = await ask("read", about: "nowhere/B")
        XCTAssertNotNil(nowhere.error, "an unlinked computer")
    }

    func testAWrongPasswordIsSaid() async {
        here.sessions = [record("A", "Mini work")]
        for _ in 0..<50 where !there.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        here.adopt(ConnectionCode(name: "Other Mac", host: "http://127.0.0.1:\(there.apiPort)", password: "wrong"))
        let read = await ask("read", about: "other-mac/B")
        XCTAssertTrue(read.error?.contains("wrong password") == true, read.error ?? "")
    }

    /// What a client connected to both does to link them: asks each for
    /// its code, and gives each the other's.
    func testAClientLinksTheComputersItHolds() async {
        here.password = "here-password"
        await here.fronted()
        await there.fronted()
        func request(_ method: String, _ path: String, _ password: String, body: String = "") -> HTTPRequest {
            HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer " + password], body: body)
        }
        var codes: [String] = []
        for server in [here!, there!] {
            let answer = server.route(request("GET", "/api/code", server.password))
            XCTAssertEqual(answer.status, 200)
            codes.append(Envelope.decode(answer.body)?.text ?? "")
        }
        var link = Envelope(type: "link")
        link.text = codes[1]
        XCTAssertEqual(here.route(request("POST", "/api/link", "here-password", body: link.encoded())).status, 200)
        link.text = codes[0]
        XCTAssertEqual(there.route(request("POST", "/api/link", "there-password", body: link.encoded())).status, 200)
        XCTAssertEqual(here.links.map(\.host), ["other-mac.example.ts.net"])
        XCTAssertEqual(there.links.map(\.host), ["this-mac.example.ts.net"])
        XCTAssertEqual(there.links.first?.password, "here-password")
        // A stranger gets no code.
        XCTAssertEqual(here.route(HTTPRequest(method: "GET", path: "/api/code", headers: [:], body: "")).status, 401)
    }

    func testLinksAreKeptAndTheLinkGoesBothWays() async {
        for _ in 0..<50 where !there.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        here.password = "here-password"
        await here.fronted()
        let code = ConnectionCode(name: "Other Mac", host: "http://127.0.0.1:\(there.apiPort)", password: "there-password")
        let result = await here.link(code.encoded)
        XCTAssertNil(result)
        XCTAssertEqual(here.links.map(\.host), [code.host])
        // The other computer took this one's code back.
        XCTAssertEqual(there.links.map(\.host), ["this-mac.example.ts.net"])
        XCTAssertEqual(VisorServer.slug("Logan’s MacBook Pro"), "logan-s-macbook-pro")
        let nonsense = await here.link("nonsense")
        XCTAssertEqual(nonsense, "That is not a connection code.")
        here.unlink(host: code.host)
        XCTAssertTrue(here.links.isEmpty)
        XCTAssertTrue(VisorServer.keptLinks().isEmpty, "kept as unlinked")
    }
}
