// Signing in to a Visor Runner (RunnerAccount, docs/runner-accounts.md):
// its servers become the store's, each reached at the Runner's path for it
// with the Runner's session as its bearer; a wrong password adds nothing;
// signed out or removed, its servers go, and computers added by hand stay.

import Foundation
import Synchronization
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A Runner's side for clients, as the test plays it: one user, two servers.
final class RunnerHTTP: VisorHTTPService {
    struct Refused: Error { let status: Int }

    private let heard = Mutex<[(method: String, url: String, headers: [String: String], body: String)]>([])
    var requests: [(method: String, url: String, headers: [String: String], body: String)] { heard.withLock { $0 } }

    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await request(method: method, url: url, body: body, headers: ["Authorization": "Bearer " + authorization])
    }

    func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        heard.withLock { $0.append((method, url, headers, body)) }
        if url.hasSuffix("/runner/v1/sign-in") {
            guard parseJSON(body)?["password"].string == "the right password" else { throw Refused(status: 401) }
            return #"{"account":"logan","expires":\#(Date().timeIntervalSince1970 + 3600),"token":"session-1"}"#
        }
        if url.hasSuffix("/runner/v1/servers") {
            guard headers["Authorization"] == "Bearer session-1" else { throw Refused(status: 401) }
            return #"{"servers":[{"id":"mini","kind":"mac","name":"Mini"},{"id":"co tenant","kind":"container","name":"Co-tenant"}]}"#
        }
        if url.hasSuffix("/runner/v1/sign-out") { return "{}" }
        // A server through the Runner, as its connection asks after it.
        return Envelope.hello(host: "Mini", login: "", token: "tok-1").encoded()
    }

    func status(of error: Error) -> Int? { (error as? Refused)?.status }
}

@MainActor
final class RunnerAccountTests: XCTestCase {
    private var http: RunnerHTTP!
    private var previousHTTP: (any VisorHTTPService)?
    private var previousSettings: (any VisorSettingsService)?

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        previousHTTP = VisorHost.http
        previousSettings = VisorHost.settings
        http = RunnerHTTP()
        VisorHost.http = http
        VisorHost.settings = MemorySettings()
    }

    override func tearDown() async throws {
        for account in RunnerAccounts.all { RunnerAccounts.remove(account.id) }
        VisorHost.http = previousHTTP
        VisorHost.settings = previousSettings
        try await super.tearDown()
    }

    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    func testSigningInBringsTheRunnersServersReachedThroughIt() async throws {
        let store = VisorStore()
        let failure = await store.signInToRunner(url: "mini.tail.ts.net:7445/", username: "logan", password: "the right password")
        XCTAssertNil(failure)
        await settle()

        let account = try XCTUnwrap(RunnerAccounts.all.first)
        XCTAssertEqual(account.url, "https://mini.tail.ts.net:7445")
        XCTAssertEqual(account.title, "logan on mini.tail.ts.net")
        XCTAssertTrue(account.isSignedIn)
        let signIn = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(signIn.method, "POST")
        XCTAssertEqual(signIn.url, "https://mini.tail.ts.net:7445/runner/v1/sign-in")
        XCTAssertEqual(parseJSON(signIn.body)?["username"].string, "logan")

        let theirs = store.servers.filter { $0.record.account == account.id }
        XCTAssertEqual(theirs.map(\.record.name).sorted(), ["Co-tenant", "Mini"])
        XCTAssertEqual(theirs.map(\.record.address).sorted(), ["https://mini.tail.ts.net:7445/runner/v1/servers/co%20tenant",
                                                               "https://mini.tail.ts.net:7445/runner/v1/servers/mini"])
        XCTAssertTrue(theirs.allSatisfy { $0.record.fromAccount && $0.record.authentication == RunnerAuthenticator.name })
        // Every request to them carries the Runner's session.
        let headers = try await AgentServerAuthenticators.authenticator(for: theirs[0].record).headers(for: theirs[0].record)
        XCTAssertEqual(headers, ["Authorization": "Bearer session-1"])

        // Kept: the account in the settings, its session with the secrets.
        let kept = VisorHost.settings?.get(key: RunnerAccounts.key) ?? ""
        XCTAssertTrue(kept.contains("mini.tail.ts.net"))
        XCTAssertFalse(kept.contains("session-1"), "the session is a secret, not a setting")
        XCTAssertEqual(VisorHost.settings?.secret(key: account.secretKey), "session-1")
    }

    func testAWrongPasswordAddsNothing() async {
        let store = VisorStore()
        let failure = await store.signInToRunner(url: "https://mini.tail.ts.net:7445", username: "logan", password: "wrong")
        XCTAssertEqual(failure, "\(AgentServerError.message("That name and password don't sign in to this Runner."))")
        XCTAssertTrue(RunnerAccounts.all.isEmpty)
        XCTAssertTrue(store.servers.allSatisfy { $0.record.account == nil })
    }

    func testSigningOutTakesItsServersAwayAndLeavesTheRest() async throws {
        let mine = AgentServerRecord(name: "Laptop", address: "http://laptop:7433", secret: "pw")
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([mine.json]).encoded())
        let store = VisorStore()
        _ = await store.signInToRunner(url: "https://mini.tail.ts.net:7445", username: "logan", password: "the right password")
        await settle()
        let account = try XCTUnwrap(RunnerAccounts.all.first)
        XCTAssertEqual(store.servers.count, 3)
        // The sidebar's grouping: the hand-added computer apart, the
        // Runner's under it.
        XCTAssertEqual(store.runners.map(\.id), [account.id])
        XCTAssertEqual(store.ownServers.map(\.record.address), ["http://laptop:7433"])
        XCTAssertEqual(store.servers(of: account).count, 2)

        store.signOut(of: account)
        await settle()
        XCTAssertFalse(account.isSignedIn)
        // By its address: connected, a computer takes its server's own name.
        XCTAssertEqual(store.servers.map(\.record.address), ["http://laptop:7433"], "the hand-added computer stays")
        XCTAssertEqual(VisorHost.settings?.secret(key: account.secretKey), "")
        XCTAssertTrue(http.requests.contains { $0.url.hasSuffix("/runner/v1/sign-out") && $0.headers["Authorization"] == "Bearer session-1" })
        XCTAssertEqual(RunnerAccounts.all.count, 1, "signed out, the account is kept to sign in to again")

        _ = await store.signInToRunner(url: "https://mini.tail.ts.net:7445", username: "logan", password: "the right password")
        await settle()
        XCTAssertEqual(RunnerAccounts.all.count, 1, "the same Runner and name: the same account")
        XCTAssertTrue(account.isSignedIn)
        store.remove(account)
        await settle()
        XCTAssertTrue(RunnerAccounts.all.isEmpty)
        XCTAssertTrue(store.runners.isEmpty)
        XCTAssertEqual(store.servers.map(\.record.address), ["http://laptop:7433"])
    }

    func testTheChannelCarriesTheSessionWhereTheSocketSendsNoHeaders() {
        var record = AgentServerRecord(name: "Mini", address: "https://mini.tail.ts.net:7445/runner/v1/servers/mini",
                                       authentication: RunnerAuthenticator.name, fromAccount: true)
        record.account = "acct-1"
        let socket = "wss://mini.tail.ts.net:7445/runner/v1/servers/mini/"
        let headers = ["Authorization": "Bearer ab+c/d="]
        // A browser's or Android's socket: on the URL, escaped.
        XCTAssertEqual(VisorAgentServer.channelURL(socket, record: record, headers: headers, sendsHeaders: false),
                       socket + "?runner_session=ab%2Bc/d%3D")
        XCTAssertEqual(VisorAgentServer.channelURL(socket + "?x=1", record: record, headers: headers, sendsHeaders: false),
                       socket + "?x=1&runner_session=ab%2Bc/d%3D")
        // URLSession's: in the header alone.
        XCTAssertEqual(VisorAgentServer.channelURL(socket, record: record, headers: headers, sendsHeaders: true), socket)
        // A computer of no Runner: never.
        let mine = AgentServerRecord(name: "Laptop", address: "http://laptop:7433", secret: "pw")
        XCTAssertEqual(VisorAgentServer.channelURL("ws://laptop:7433/", record: mine, headers: ["Authorization": "Bearer pw"], sendsHeaders: false),
                       "ws://laptop:7433/")
    }

    func testARecordKeepsItsAccount() throws {
        var record = AgentServerRecord(name: "Mini", address: "https://runner.example/runner/v1/servers/mini", fromAccount: true)
        record.account = "acct-1"
        let read = try XCTUnwrap(AgentServerRecord(json: record.json))
        XCTAssertEqual(read.account, "acct-1")
        XCTAssertNil(AgentServerRecord(json: AgentServerRecord(name: "Laptop", address: "http://laptop:7433").json)?.account)
        XCTAssertEqual(RunnerAccounts.normalized("  runner.example:7445//  "), "https://runner.example:7445")
        XCTAssertEqual(RunnerAccounts.normalized("http://10.0.0.2:7445"), "http://10.0.0.2:7445")
    }
}
