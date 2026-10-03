// How a client gets into a server: its provider's sign-in first, then the
// live channel. A refusal is the server asking the user to sign in, shown
// as such and not retried. For a Mac the sign-in is `hello` over HTTP —
// let in on the network's word or the password, refused with 401
// otherwise — and the channel is the socket, logged in with the token
// hello gave; `TailscaleSignInTests` covers that over scripted services.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A server that answers as the test scripts it.
final class ScriptedServer: AgentServer {
    /// What signing in answers: a name, or a failure.
    var signIn: Result<String?, Error> = .success("Scripted Mac")
    var channels = 0
    var subscribed: [String] = []
    var actions: [(SessionAction, String)] = []
    private var onEvent: (@MainActor (AgentServerEvent) -> Void)?

    func authenticate(_ record: AgentServerRecord) async throws -> String? { try signIn.get() }

    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void) {
        channels += 1
        self.onEvent = onEvent
        let name = (try? signIn.get()) ?? nil
        Task { onEvent(.welcome(name: name ?? "", sessions: [], catalogs: [])) }
    }

    func closeChannel() {}

    /// The pauses asked for, each held until the test lets it go.
    private(set) var pauses: [Int32] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func delay(milliseconds: Int32) async {
        pauses.append(milliseconds)
        await withCheckedContinuation { held.append($0) }
    }

    /// Lets the oldest pause of this length end.
    func elapse(_ milliseconds: Int32) {
        guard let index = pauses.firstIndex(of: milliseconds) else { return }
        pauses.remove(at: index)
        held.remove(at: index).resume()
    }

    /// Ends the channel as the server would, or as a heartbeat would.
    func drop(_ reason: String) { onEvent?(.closed(reason)) }

    /// Whether the open channel answers when asked outright.
    var alive = true
    var verified = 0
    func verifyChannel() async -> Bool { verified += 1; return alive }

    /// What asking for the sessions outright answers.
    var listed: Result<[SessionInfo], Error> = .success([])
    var asked = 0
    func sessions() async throws -> [SessionInfo] { asked += 1; return try listed.get() }

    func subscribe(_ session: String) { subscribed.append(session) }
    func assumeControl(_ session: String, cols: Int, rows: Int) {}
    func returnToChat(_ session: String) {}
    func acknowledge(_ session: String) {}
    func loadEarlier(_ session: String, before: String) {}
    func sendInput(_ session: String, data: String) {}
    func resize(_ session: String, cols: Int, rows: Int) {}

    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo] { [] }
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo] { actions.append((action, session)); return [] }
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo] { [] }
    func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope {
        // Nothing moves: held, as a server holds it.
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 60_000_000_000) }
        throw CancellationError()
    }
    func commands(for session: String) async throws -> [SlashCommand] { [] }
    func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession] { [] }
    func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo] { [] }
    func folders(at path: String) async throws -> FolderListing { FolderListing(path: path, folders: []) }
    func makeFolder(_ path: String) async throws -> String { path }
    func fileData(path: String) async throws -> String { "" }
    func upload(base64: String, name: String) async throws -> String { name }
    func search(_ query: String) async throws -> [SearchHit] { [] }
}

struct ScriptedProvider: AgentServerProvider {
    let id = "scripted"
    let title = "Scripted"
    @MainActor static var server = ScriptedServer()
    @MainActor func makeServer(for record: AgentServerRecord) -> any AgentServer { Self.server }
}

@MainActor
final class MemorySettings: VisorSettingsService {
    var values: [String: String] = [:]
    func get(key: String) -> String { values[key] ?? "" }
    func set(key: String, value: String) { values[key] = value }
}

@MainActor
final class HelloFlowTests: XCTestCase {
    private var server: ScriptedServer!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        server = ScriptedServer()
        ScriptedProvider.server = server
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testSignInThenChannel() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.record.name, "Scripted Mac")
        XCTAssertTrue(host.record.everConnected)
        XCTAssertEqual(server.channels, 1)
    }

    func testARefusedSignInAsksTheUser() async {
        server.signIn = .failure(AgentServerError.needsAuthentication)
        let host = AgentServerConnection(record: AgentServerRecord(name: "Other", address: "other.example", provider: "scripted"))
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .needsAuthentication)
        XCTAssertTrue(host.state.wantsAuthentication)
        // No channel was opened, and nothing keeps retrying.
        XCTAssertEqual(server.channels, 0)
        XCTAssertEqual(host.badge, .unreachable)

        // With the credentials saved, the server lets it in.
        server.signIn = .success("Other Mac")
        host.update { $0.secret = "pearl-grove" }
        host.connect()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(host.record.name, "Other Mac")
    }

    /// After a drop the channel is tried again after 2, 4, 8 and 16
    /// seconds, then every 30.
    func testTheRetrySchedule() {
        XCTAssertEqual((1...7).map(AgentServerConnection.retryDelay(afterAttempt:)), [2, 4, 8, 16, 30, 30, 30])
    }

    func testADropIsRetriedOnTheSchedule() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        server.signIn = .failure(AgentServerError.message("away"))
        server.drop("No answer to a heartbeat")
        await settle()
        XCTAssertEqual(host.state, .offline("No answer to a heartbeat"))
        XCTAssertTrue(server.pauses.contains(2000))
        server.elapse(2000)
        await settle()
        XCTAssertTrue(server.pauses.contains(4000), "the sign-in failed again: the next wait is twice as long")
        server.signIn = .success("Scripted Mac")
        server.elapse(4000)
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(server.channels, 2)
    }

    /// Back in front: a server that is not connected is tried at once,
    /// from the start of the schedule; one that looks connected is asked
    /// whether it is, and opened afresh only if it does not answer; one
    /// waiting for the user to sign in is left alone.
    func testComingBackToTheFrontReconnects() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        host.resume()
        await settle()
        XCTAssertEqual(server.verified, 1)
        XCTAssertEqual(server.channels, 1, "it answered: nothing is reopened")

        server.alive = false
        host.resume()
        await settle()
        XCTAssertEqual(server.channels, 2, "it did not: opened afresh")
        XCTAssertEqual(host.state, .connected)

        // Dropped, and waiting out a retry: the front does not wait.
        server.signIn = .failure(AgentServerError.message("away"))
        server.drop("connection lost")
        await settle()
        server.elapse(2000)
        await settle()
        XCTAssertEqual(host.state, .offline("message(\"away\")"))
        server.signIn = .success("Scripted Mac")
        host.resume()
        await settle()
        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(server.channels, 3)

        // Asked to sign in: coming to the front does not retry by itself.
        let other = ScriptedServer()
        other.signIn = .failure(AgentServerError.needsAuthentication)
        ScriptedProvider.server = other
        let locked = AgentServerConnection(record: AgentServerRecord(name: "", address: "other.example", provider: "scripted"))
        locked.connect()
        await settle()
        locked.resume()
        await settle()
        XCTAssertEqual(locked.state, .needsAuthentication)
        XCTAssertEqual(other.channels, 0)
    }

    /// After time in the background on a phone the channel is opened
    /// afresh without being asked; and a try that fails just after coming
    /// back (the network a moment behind the app) is tried again at once,
    /// three times, before the schedule takes over.
    func testBackFromTheBackgroundOpensAfreshAndRetriesQuickly() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        host.resume(fresh: true)
        await settle()
        XCTAssertEqual(server.verified, 0, "not asked")
        XCTAssertEqual(server.channels, 2, "opened afresh")
        XCTAssertEqual(host.state, .connected)

        server.signIn = .failure(AgentServerError.message("no route yet"))
        host.resume(fresh: true)
        await settle()
        for _ in 0..<3 {
            XCTAssertTrue(server.pauses.contains(300), "tried again at once")
            XCTAssertFalse(server.pauses.contains(2000))
            server.elapse(300)
            await settle()
        }
        XCTAssertTrue(server.pauses.contains(2000), "then the schedule")
        server.signIn = .success("Scripted Mac")
        server.elapse(2000)
        await settle()
        XCTAssertEqual(host.state, .connected)
    }

    /// Every minute the sessions are asked for outright: taken as the list
    /// while the channel is up, and the cue to open it again at once when
    /// it is down and the server answers.
    func testTheMinutePollIsTheBackup() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        XCTAssertTrue(server.pauses.contains(60_000))
        server.listed = .success([SessionInfo(id: "s1", agent: .claude, cwd: "/tmp", title: "Polled", created: 0)])
        server.elapse(60_000)
        await settle()
        XCTAssertEqual(server.asked, 1)
        XCTAssertEqual(host.sessions.map(\.title), ["Polled"], "a list the channel did not bring")

        // The channel drops and the retries find nothing; the poll does.
        server.signIn = .failure(AgentServerError.message("away"))
        server.drop("connection lost")
        await settle()
        server.elapse(2000)
        await settle()
        XCTAssertEqual(host.state, .offline("message(\"away\")"))
        server.signIn = .success("Scripted Mac")
        server.elapse(60_000)
        await settle()
        XCTAssertEqual(host.state, .connected, "reopened on the poll's answer, not at the next retry")
    }

    /// A session command goes to the server as the typed action, and
    /// ending a session is one too.
    func testCommandsReachTheServerAsActions() async {
        let host = AgentServerConnection(record: AgentServerRecord(name: "", address: "mac.example", provider: "scripted"))
        host.connect()
        await settle()
        host.subscribe("s1")
        host.rename("s1", title: "Plans")
        host.end("s1")
        await settle()
        XCTAssertEqual(server.subscribed, ["s1"])
        XCTAssertEqual(server.actions.map(\.0), [.rename(title: "Plans"), .end])
        XCTAssertEqual(server.actions.map(\.1), ["s1", "s1"])
    }

    func testPasswordsAreKeptAsSecrets() {
        let settings = MemorySettings()
        VisorHost.settings = settings
        // Saved as an earlier build did: the password inside the config.
        settings.values["hosts"] = #"[{"id":"h1","name":"Mini","host":"mini.example","password":"pearl-grove","backend":"scripted"}]"#
        let store = VisorStore()
        XCTAssertEqual(store.servers.first?.record.secret, "pearl-grove")
        XCTAssertEqual(store.servers.first?.record.address, "mini.example")
        XCTAssertEqual(store.servers.first?.record.provider, "scripted")
        // Moved out of the record into the secrets, and read from there.
        XCTAssertFalse(settings.values["hosts"]?.contains("pearl-grove") ?? true)
        XCTAssertEqual(settings.secret(key: "password.h1"), "pearl-grove")
        XCTAssertEqual(VisorStore().servers.first?.record.secret, "pearl-grove")
        // Removing the server forgets its secret.
        store.remove(store.servers[0])
        XCTAssertEqual(settings.secret(key: "password.h1"), "")
    }

    func testAConnectionCodeAddsTheComputer() async {
        let store = VisorStore()
        let code = ConnectionCode(name: "Studio Mac", host: "mini.example", password: "pearl-grove")
        XCTAssertNil(store.open("not a code"))
        let host = store.open(code.link)
        XCTAssertEqual(host?.record.address, "mini.example")
        XCTAssertEqual(host?.record.secret, "pearl-grove")
        XCTAssertEqual(host?.record.name, "Studio Mac")
        XCTAssertEqual(host?.record.provider, "tailscale")
        // The same computer again (a pasted code): updated, not doubled.
        store.open(ConnectionCode(name: "Mini", host: "mini.example", password: "new-pass").encoded)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers.first?.record.secret, "new-pass")
    }
}
