// How the client proves itself, apart from how it reaches the server:
// the password goes as a bearer, none sends nothing, a fork's own goes
// as whatever headers it gives; the record names which, the password
// unless said otherwise.

import Foundation
import Synchronization
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// HTTP that keeps the headers it was given.
final class HeaderKeepingHTTP: VisorHTTPService {
    private let kept = Mutex<[[String: String]]>([])
    var headers: [[String: String]] { kept.withLock { $0 } }
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await request(method: method, url: url, body: body, headers: ["Authorization": "Bearer " + authorization])
    }
    func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        kept.withLock { $0.append(headers) }
        return Envelope.hello(host: "Mini", login: "", token: "tok-1").encoded()
    }
    func status(of error: Error) -> Int? { nil }
}

/// A company's own: a token in a header of its own.
struct BadgeAuthenticator: AgentServerAuthenticator {
    let id = "badge"
    let title = "Badge"
    func headers(for record: AgentServerRecord) async throws -> [String: String] {
        guard !record.secret.isEmpty else { throw AgentServerError.needsAuthentication }
        return ["X-Badge": record.secret]
    }
}

@MainActor
final class AuthenticatorTests: XCTestCase {
    private var http: HeaderKeepingHTTP!

    override func setUp() async throws {
        try await super.setUp()
        http = HeaderKeepingHTTP()
        VisorHost.http = http
        VisorHost.settings = MemorySettings()
    }

    func testThePasswordGoesAsABearerAndNoneSendsNothing() async throws {
        let password = AgentServerRecord(name: "Mini", address: "http://10.0.0.2:7433", secret: "pw")
        _ = try await VisorAgentServer(record: password).authenticate(password)
        XCTAssertEqual(http.headers.last, ["Authorization": "Bearer pw"])
        let none = AgentServerRecord(name: "Mini", address: "http://10.0.0.2:7433", authentication: NoAuthenticator.name)
        _ = try await VisorAgentServer(record: none).authenticate(none)
        XCTAssertEqual(http.headers.last, [:])
        // Kept and read back; the password for a record from before.
        XCTAssertEqual(AgentServerRecord(json: none.json)?.authentication, "none")
        XCTAssertEqual(AgentServerRecord(json: .object(["id": .string("x"), "address": .string("a")]))?.authentication, "password")
        XCTAssertEqual(AgentServerAuthenticators.authenticator(for: AgentServerRecord(name: "", address: "a", authentication: "nobody")).id, "password")
    }

    /// A fork's authenticator: its own headers, and a sign-in asked for
    /// when it has nothing to send.
    func testAForksAuthenticatorGivesItsOwnHeaders() async throws {
        AgentServerAuthenticators.register(BadgeAuthenticator())
        XCTAssertEqual(AgentServerAuthenticators.all.map(\.id), ["password", "none", "badge"])
        let badge = AgentServerRecord(name: "Sandbox", address: "https://agents.example.com/visor", secret: "t0k", authentication: "badge")
        _ = try await VisorAgentServer(record: badge).authenticate(badge)
        XCTAssertEqual(http.headers.last, ["X-Badge": "t0k"])
        let signedOut = AgentServerRecord(name: "Sandbox", address: "https://agents.example.com/visor", authentication: "badge")
        do {
            _ = try await VisorAgentServer(record: signedOut).authenticate(signedOut)
            XCTFail("signed in with nothing")
        } catch AgentServerError.needsAuthentication {}
    }

    /// A host with only the bearer form of the HTTP service gets the
    /// bearer out of the headers.
    func testAHostWithOnlyTheBearerFormStillSendsIt() async throws {
        final class BearerOnly: VisorHTTPService {
            let kept = Mutex<[String]>([])
            func request(method: String, url: String, body: String, authorization: String) async throws -> String {
                kept.withLock { $0.append(authorization) }
                return ""
            }
        }
        let host = BearerOnly()
        _ = try await host.request(method: "GET", url: "u", body: "", headers: ["Authorization": "Bearer abc"])
        _ = try await host.request(method: "GET", url: "u", body: "", headers: [:])
        XCTAssertEqual(host.kept.withLock { $0 }, ["abc", ""])
    }
}
