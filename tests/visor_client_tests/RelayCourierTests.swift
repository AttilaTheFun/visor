// The client's part in the relay: it tells each server it holds what it
// is connected to, and carries each server's messages to the server they
// are for, bringing back what became of them — unless the user (or a
// fork, by default) turned that off for a computer.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class RelayCourierTests: XCTestCase {
    private var store: VisorStore!
    private var mini: ScriptedServer!
    private var laptop: ScriptedServer!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
        VisorHost.deviceName = "Logan's iPhone"
        RelayCourier.onByDefault = true
    }

    override func tearDown() async throws {
        RelayCourier.onByDefault = true
        VisorHost.deviceName = ""
        try await super.tearDown()
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Two computers held, connected, each with its sessions.
    private func hold(miniRelay: Bool? = nil, laptopRelay: Bool? = nil) async {
        let a = AgentServerRecord(name: "Mini", address: "http://mini:7433", secret: "a", provider: "scripted", relay: miniRelay)
        let b = AgentServerRecord(name: "Laptop", address: "http://laptop:7433", secret: "b", provider: "scripted", relay: laptopRelay)
        mini = ScriptedServer()
        laptop = ScriptedServer()
        ScriptedProvider.servers = [a.id: mini, b.id: laptop]
        mini.signIn = .success("Mini")
        laptop.signIn = .success("Laptop")
        mini.identity = ServerIdentity(id: "mini-id", addresses: [])
        laptop.identity = ServerIdentity(id: "laptop-id", addresses: [])
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json]).encoded())
        store = VisorStore()
        for _ in 0..<10 { await settle() }
        var archived = SessionInfo(id: "Z", agent: .claude, cwd: "/", title: "Old", created: 0)
        archived.archived = true
        var working = SessionInfo(id: "B", agent: .claude, cwd: "/", title: "Laptop work", created: 0)
        working.busy = true
        mini.deliver(.sessions([SessionInfo(id: "A", agent: .claude, cwd: "/", title: "", created: 0)]))
        laptop.deliver(.sessions([working, archived]))
        await settle()
        mini.reports = []
        laptop.reports = []
    }

    private func message(_ id: String, to server: String) -> RelayMessage {
        RelayMessage(id: id, kind: .send, from: RelayEndpoint(server: "mini-id", serverName: "Mini", session: "A"),
                     to: RelayEndpoint(server: server, serverName: "Laptop", session: "B"), text: "Hi", created: 0, expires: 1)
    }

    func testEachServerIsToldWhatTheDeviceIsConnectedTo() async throws {
        await hold()
        await store.courier.exchangeAll()
        let report = try XCTUnwrap(mini.reports.last)
        XCTAssertEqual(laptop.reports.last, report, "the same to each")
        XCTAssertEqual(report.client, AgentServerRecord.clientID)
        XCTAssertEqual(report.clientName, "Logan's iPhone")
        XCTAssertEqual(report.servers.map(\.id), ["mini-id", "laptop-id"])
        XCTAssertEqual(report.servers.map(\.name), ["Mini", "Laptop"])
        // What an agent can message: not the archived; untitled, by its
        // agent's name.
        let claude = AgentKind.claude.title
        XCTAssertEqual(report.servers[0].sessions, [DirectorySession(id: "A", name: claude, agent: claude, busy: false)])
        XCTAssertEqual(report.servers[1].sessions, [DirectorySession(id: "B", name: "Laptop work", agent: claude, busy: true)])
    }

    func testAMessageIsCarriedAndItsReceiptBroughtBack() async {
        await hold()
        mini.outbox = [message("m1", to: "laptop-id"), message("m2", to: "elsewhere")]
        await store.courier.exchangeAll()
        XCTAssertEqual(laptop.carriedHere.map(\.id), ["m1"], "only what is for a server held here")
        XCTAssertEqual(mini.receipts, [RelayReceipt(message: "m1", outcome: .sent)])
        await store.courier.exchangeAll()
        XCTAssertEqual(laptop.carriedHere.map(\.id), ["m1"], "not carried again once confirmed")
    }

    func testTheServerSayingItHasMessagesIsAnsweredAtOnce() async {
        await hold()
        mini.outbox = [message("m1", to: "laptop-id")]
        mini.deliver(.relay)
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(laptop.carriedHere.map(\.id), ["m1"])
        XCTAssertEqual(mini.receipts.map(\.message), ["m1"])
    }

    func testAComputerTurnedOffIsToldNothingAndCarriesNothing() async throws {
        await hold(laptopRelay: false)
        mini.outbox = [message("m1", to: "laptop-id")]
        await store.courier.exchangeAll()
        XCTAssertTrue(laptop.reports.isEmpty, "told nothing")
        XCTAssertEqual(mini.reports.last?.servers.map(\.id), ["mini-id"], "and told of to no one")
        XCTAssertTrue(laptop.carriedHere.isEmpty)

        // Turned off after it was told: told once that there is nothing.
        let miniHost = try XCTUnwrap(store.servers.first { $0.record.serverID == "mini-id" })
        miniHost.update { $0.relay = false }
        await store.courier.exchangeAll()
        XCTAssertEqual(mini.reports.last?.servers, [], "withdrawn")
        let count = mini.reports.count
        await store.courier.exchangeAll()
        XCTAssertEqual(mini.reports.count, count, "and nothing after")
        XCTAssertEqual(AgentServerRecord(json: miniHost.record.json)?.relay, false, "kept")
    }

    func testAServerFromBeforeTheRelayIsLeftAloneForAWhile() async {
        await hold()
        laptop.refusesReports = true
        await store.courier.exchangeAll()
        XCTAssertEqual(mini.reports.last?.servers.map(\.id), ["mini-id", "laptop-id"], "not yet known to refuse")
        mini.outbox = [message("m1", to: "laptop-id")]
        await store.courier.exchangeAll()
        XCTAssertEqual(mini.reports.last?.servers.map(\.id), ["mini-id"], "resting: not told of")
        XCTAssertTrue(laptop.carriedHere.isEmpty, "nor carried to")
        // Updated and connected again: asked at once.
        laptop.refusesReports = false
        let laptopHost = store.servers.first { $0.record.serverID == "laptop-id" }!
        await store.courier.connected(laptopHost)
        XCTAssertFalse(laptop.reports.isEmpty)
        XCTAssertEqual(laptop.carriedHere.map(\.id), ["m1"])
    }

    func testAForkCanTurnItOffByDefault() async {
        RelayCourier.onByDefault = false
        await hold(laptopRelay: true)
        await store.courier.exchangeAll()
        XCTAssertTrue(mini.reports.isEmpty)
        XCTAssertEqual(laptop.reports.last?.servers.map(\.id), ["laptop-id"], "the one the user turned on")
    }
}
