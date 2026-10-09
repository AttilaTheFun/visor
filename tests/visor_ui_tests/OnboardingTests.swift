// When the default onboarding shows: while there are no computers, and not
// where the app has an account (its sign-in brings the computers).

import VisorClient
import VisorServices
@testable import VisorUI
import XCTest

/// Settings kept in memory, for a store that reads none of the real ones.
@MainActor
private final class MemorySettings: VisorSettingsService {
    var values: [String: String] = [:]
    func get(key: String) -> String { values[key] ?? "" }
    func set(key: String, value: String) { values[key] = value }
}

/// An account that never signs in.
@MainActor
private final class IdleAccount: VisorAccount {
    let title = "Okta"
    let isSignedIn = false
    func signIn() async throws {}
    func signOut() {}
    func servers() async throws -> [AgentServerRecord] { [] }
    func headers(for record: AgentServerRecord) async throws -> [String: String] { [:] }
}

@MainActor
final class OnboardingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        VisorHost.settings = MemorySettings()
        VisorAccounts.current = nil
    }

    override func tearDown() async throws {
        VisorAccounts.current = nil
        try await super.tearDown()
    }

    func testTheDefaultOnboardingShowsUntilThereIsAComputer() {
        let store = VisorStore()
        let onboarding = DefaultOnboarding()
        XCTAssertTrue(onboarding.isNeeded(store))
        store.add(AgentServerRecord(name: "Mini", address: "http://mini.invalid:7433"))
        XCTAssertFalse(onboarding.isNeeded(store))
        XCTAssertTrue(VisorOnboardings.current is DefaultOnboarding, "the default unless a fork sets one")
    }

    func testNotWhereTheAppHasAnAccount() {
        VisorAccounts.current = IdleAccount()
        let store = VisorStore()
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertFalse(DefaultOnboarding().isNeeded(store))
    }
}
