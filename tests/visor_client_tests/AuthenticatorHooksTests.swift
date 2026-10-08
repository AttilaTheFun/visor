// What an authenticator can do beyond headers: tell of the other servers
// behind its front once one has connected (the store adds those it does
// not hold), and say that it signed in once for many records (those of
// them waiting for it connect again).

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A company's SSO: one sign-in for every server behind its front, which
/// it tells of.
@MainActor
struct SSOAuthenticator: AgentServerAuthenticator {
    static let name = "sso"
    let id = SSOAuthenticator.name
    let title = "SSO"
    @MainActor static var behindTheFront: [AgentServerRecord] = []
    func headers(for record: AgentServerRecord) async throws -> [String: String] { [:] }
    func discover(from record: AgentServerRecord) async throws -> [AgentServerRecord] { Self.behindTheFront }
}

@MainActor
final class AuthenticatorHooksTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        AgentServerAuthenticators.register(SSOAuthenticator())
        SSOAuthenticator.behindTheFront = []
        VisorHost.settings = MemorySettings()
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func scripted(_ record: AgentServerRecord) -> ScriptedServer {
        let server = ScriptedServer()
        ScriptedProvider.servers[record.id] = server
        return server
    }

    private func sso(_ name: String, _ address: String) -> AgentServerRecord {
        AgentServerRecord(name: name, address: address, secret: "", provider: "scripted", authentication: SSOAuthenticator.name)
    }

    /// One sign-in shows every computer: the servers the authenticator
    /// tells of are added, those held already are not added again.
    func testTheServersBehindTheFrontAreAdded() async {
        let first = sso("Sandbox 1", "https://front.example.com/one")
        let held = AgentServerRecord(name: "Mini", address: "http://mini:7433", secret: "pw", provider: "scripted")
        scripted(first).identity = ServerIdentity(id: "one", addresses: [], standalone: true)
        scripted(held).identity = ServerIdentity(id: "mini", addresses: ["http://mini:7433"])
        SSOAuthenticator.behindTheFront = [sso("Sandbox 1", "https://front.example.com/one"),
                                           sso("Sandbox 2", "https://front.example.com/two"),
                                           AgentServerRecord(name: "Mini", address: "http://mini:7433", secret: "", provider: "scripted")]
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([first.json, held.json]).encoded())
        let store = VisorStore()
        for _ in 0..<10 { await settle() }
        XCTAssertEqual(store.servers.map(\.record.address).sorted(),
                       ["http://mini:7433", "https://front.example.com/one", "https://front.example.com/two"])
        let second = store.servers.first { $0.record.address == "https://front.example.com/two" }
        XCTAssertEqual(second?.record.authentication, SSOAuthenticator.name)
        XCTAssertEqual(store.servers.first { $0.record.address == "http://mini:7433" }?.record.secret, "pw", "a held one is left as it is")
    }

    /// One sign-in for many records: those that sign in by it and were
    /// waiting for it connect again; others are left; `serving` narrows
    /// it to one front's.
    func testOneSignInReconnectsTheRecordsWaitingForIt() async {
        let a = sso("A", "https://front-a.example.com/visor")
        let b = sso("B", "https://front-b.example.com/visor")
        let other = AgentServerRecord(name: "Mini", address: "http://mini:7433", secret: "", provider: "scripted")
        let servers = [a, b, other].map(scripted)
        for server in servers { server.signIn = .failure(AgentServerError.needsAuthentication) }
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([a.json, b.json, other.json]).encoded())
        let store = VisorStore()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.map(\.state), [.needsAuthentication, .needsAuthentication, .needsAuthentication])

        for server in servers { server.signIn = .success("Signed in") }
        AgentServerAuthenticators.signedIn(SSOAuthenticator.name) { $0.address.hasPrefix("https://front-a.") }
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.map(\.state), [.connected, .needsAuthentication, .needsAuthentication])

        AgentServerAuthenticators.signedIn(SSOAuthenticator.name)
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.map(\.state), [.connected, .connected, .needsAuthentication], "the password's waits for its own")
    }
}
