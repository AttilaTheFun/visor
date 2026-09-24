// How a client gets into a computer: `hello` over HTTP first — let in on
// the network's word or the password, refused with 401 otherwise — then
// the socket, logged in with the token hello gave. A 401 is the computer
// asking for a password, shown as such and not retried.

@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A road whose computer answers as the test scripts it.
final class ScriptedTransport: HostTransport, @unchecked Sendable {
    /// What `GET /hello` answers: a body, or a status to fail with.
    var hello: Result<String, ScriptedFailure> = .success(Envelope.hello(host: "Scripted Mac", login: "owner@example.com", token: "tok-1").encoded())
    var sent: [String] = []
    var connected = 0
    private var onEvent: (@MainActor (TransportEvent) -> Void)?

    func connect(_ config: HostConfig, onEvent: @escaping @MainActor (TransportEvent) -> Void) {
        connected += 1
        self.onEvent = onEvent
        Task { @MainActor in onEvent(.opened) }
    }

    func send(_ text: String) {
        sent.append(text)
        // The computer answers a login it accepts with welcome.
        if let envelope = Envelope.decode(text), envelope.type == "login" {
            let reply: Envelope = envelope.token == "tok-1" ? .welcome(host: "Scripted Mac", sessions: [], catalogs: []) : .error("Wrong password")
            Task { @MainActor in self.onEvent?(.message(reply.encoded())) }
        }
    }

    func disconnect() {}

    func call(_ method: String, _ path: String, body: String, config: HostConfig) async throws -> String {
        if path == "/hello" { return try hello.get() }
        return Envelope(type: "reply").encoded()
    }

    func status(of error: Error) -> Int? { (error as? ScriptedFailure)?.status }
    func delay(milliseconds: Int32) async {}
}

struct ScriptedFailure: Error { let status: Int }

struct ScriptedBackend: Backend {
    let id = "scripted"
    let title = "Scripted"
    let hostFieldTitle = "Host"
    let hostPlaceholder = ""
    let passwordFieldTitle = "Password"
    let help = ""
    nonisolated(unsafe) static var transport = ScriptedTransport()
    func makeTransport() -> any HostTransport { Self.transport }
}

final class MemorySettings: VisorSettingsService {
    var values: [String: String] = [:]
    func get(key: String) -> String { values[key] ?? "" }
    func set(key: String, value: String) { values[key] = value }
}

@MainActor
final class HelloFlowTests: XCTestCase {
    private var transport: ScriptedTransport!

    override func setUp() {
        super.setUp()
        HostConnection.cache = .inMemory()
        transport = ScriptedTransport()
        ScriptedBackend.transport = transport
        Backends.register(ScriptedBackend())
        VisorHost.settings = MemorySettings()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testHelloThenTokenLogin() async {
        let host = HostConnection(config: HostConfig(name: "", host: "mac.example", password: "", backend: "scripted"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.config.name, "Scripted Mac")
        XCTAssertTrue(host.config.everConnected)
        XCTAssertEqual(transport.connected, 1)
        let login = transport.sent.compactMap { Envelope.decode($0) }.first { $0.type == "login" }
        XCTAssertEqual(login?.token, "tok-1")
        XCTAssertEqual(login?.password, "")
    }

    func testRefusedHelloAsksForAPassword() async {
        transport.hello = .failure(ScriptedFailure(status: 401))
        let host = HostConnection(config: HostConfig(name: "Other", host: "other.example", password: "", backend: "scripted"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .needsPassword)
        XCTAssertTrue(host.state.wantsPassword)
        // No socket was opened, and nothing keeps retrying.
        XCTAssertEqual(transport.connected, 0)
        XCTAssertEqual(host.badge, .unreachable)

        // With the password saved, the computer lets it in.
        transport.hello = .success(Envelope.hello(host: "Other Mac", login: "owner@example.com", token: "tok-1").encoded())
        host.update { $0.password = "pearl-grove" }
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
    }

    func testAConnectionCodeAddsTheComputer() async {
        let store = VisorStore()
        let code = ConnectionCode(name: "Studio Mac", host: "mini.example", password: "pearl-grove")
        XCTAssertNil(store.open("not a code"))
        let host = store.open(code.link)
        XCTAssertEqual(host?.config.host, "mini.example")
        XCTAssertEqual(host?.config.password, "pearl-grove")
        XCTAssertEqual(host?.config.name, "Studio Mac")
        // The same computer again (a pasted code): updated, not doubled.
        store.open(ConnectionCode(name: "Mini", host: "mini.example", password: "new-pass").encoded)
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts.first?.config.password, "new-pass")
    }
}
