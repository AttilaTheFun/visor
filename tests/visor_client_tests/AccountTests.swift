// The app's account (VisorAccount): signed out, none of its servers; signed
// in, its servers are the store's and every request carries its headers; a
// changed list is followed; signed out again, its servers go and the
// computers added by hand stay.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

/// A company's single sign-on, as the test drives it.
@MainActor
final class ScriptedAccount: VisorAccount {
    let title = "Okta"
    var isSignedIn = false
    var listed: [AgentServerRecord] = []

    func signIn() async throws { isSignedIn = true }
    func signOut() { isSignedIn = false }
    func servers() async throws -> [AgentServerRecord] { listed }
    func headers(for record: AgentServerRecord) async throws -> [String: String] {
        guard isSignedIn else { throw AgentServerError.needsAuthentication }
        return ["Authorization": "Bearer okta-token"]
    }
}

@MainActor
final class AccountTests: XCTestCase {
    private var account: ScriptedAccount!

    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
        account = ScriptedAccount()
        account.listed = ["Build Box", "GPU Box", "Staging"].enumerated().map { index, name in
            AgentServerRecord(name: name, address: "https://front.example.com/visor/\(index)", provider: "scripted", serverID: "box-\(index)")
        }
        VisorAccounts.current = account
    }

    override func tearDown() async throws {
        VisorAccounts.current = nil
        try await super.tearDown()
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func testSigningInBringsTheAccountsServersAndOutTakesThemAway() async throws {
        let mine = AgentServerRecord(name: "Mini", address: "http://mini:7433", secret: "pw", provider: "scripted")
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([mine.json]).encoded())
        let store = VisorStore()
        XCTAssertFalse(store.accountSignedIn)
        XCTAssertEqual(store.servers.map(\.record.address), ["http://mini:7433"])

        let failure = await store.signInAccount()
        XCTAssertNil(failure)
        for _ in 0..<5 { await settle() }
        XCTAssertTrue(store.accountSignedIn)
        let fromAccount = store.servers.filter(\.record.fromAccount)
        XCTAssertEqual(fromAccount.map(\.record.name).sorted(), ["Build Box", "GPU Box", "Staging"])
        XCTAssertTrue(fromAccount.allSatisfy { $0.record.authentication == VisorAccounts.authenticatorID })
        // Every request to them carries the account's headers.
        let headers = try await AgentServerAuthenticators.authenticator(for: fromAccount[0].record).headers(for: fromAccount[0].record)
        XCTAssertEqual(headers, ["Authorization": "Bearer okta-token"])

        // The account lists one fewer and one more: followed.
        account.listed.removeLast()
        account.listed.append(AgentServerRecord(name: "Render Box", address: "https://front.example.com/visor/9", provider: "scripted",
                                                serverID: "box-9"))
        VisorAccounts.changed()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.filter(\.record.fromAccount).map(\.record.name).sorted(), ["Build Box", "GPU Box", "Render Box"])

        store.signOutAccount()
        XCTAssertFalse(store.accountSignedIn)
        XCTAssertEqual(store.servers.map(\.record.address), ["http://mini:7433"], "the computer added by hand stays")
        do {
            _ = try await AccountAuthenticator().headers(for: fromAccount[0].record)
            XCTFail("signed out: no headers")
        } catch {
            XCTAssertEqual(error as? AgentServerError, .needsAuthentication)
        }
    }

    /// Kept from a run when the account was signed in, then launched signed
    /// out: its servers are not shown.
    func testAnAccountSignedOutAtLaunchShowsNoneOfItsServers() {
        var kept = AgentServerRecord(name: "Build Box", address: "https://front.example.com/visor/0", provider: "scripted")
        kept.fromAccount = true
        VisorHost.settings?.set(key: "hosts", value: JSONValue.array([kept.json]).encoded())
        let store = VisorStore()
        XCTAssertFalse(store.accountSignedIn)
        XCTAssertTrue(store.servers.isEmpty)
    }

    /// The fixture's account, asked for by the setting: three computers once
    /// signed in.
    func testTheFixturesAccountReachesThreeComputers() async {
        VisorAccounts.current = nil
        VisorHost.settings?.set(key: "account", value: "fixture")
        let store = VisorStore()
        XCTAssertTrue(VisorAccounts.current is FixtureAccount)
        XCTAssertFalse(store.accountSignedIn)
        _ = await store.signInAccount()
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(store.servers.map(\.record.name), ["Build Box", "GPU Box", "Staging"])
    }
}
