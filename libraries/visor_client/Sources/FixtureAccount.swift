import VisorProtocol

/// An account to try the account's sign-in with, as a fork's would be:
/// signing in (a moment's wait, as a web sign-in takes) reaches three
/// computers behind one front, each the canned server
/// (`FixtureAgentServerProvider`). Used when the setting `account` is
/// "fixture" (on Apple `-visor.account fixture` at launch), or
/// "fixture-signed-in" to start signed in.
@MainActor
public final class FixtureAccount: VisorAccount {
    public let title = "Fixture SSO"
    public private(set) var isSignedIn: Bool

    public init(signedIn: Bool = false) { isSignedIn = signedIn }

    public func signIn() async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
        isSignedIn = true
    }

    public func signOut() { isSignedIn = false }

    public func servers() async throws -> [AgentServerRecord] {
        guard isSignedIn else { throw AgentServerError.needsAuthentication }
        return ["Build Box", "GPU Box", "Staging"].enumerated().map { index, name in
            AgentServerRecord(id: "fixture-account-\(index)", name: name, address: "https://front.example.com/visor/\(index)",
                              provider: FixtureAgentServerProvider.name, renamed: true, serverID: "fixture-account-\(index)")
        }
    }

    public func headers(for record: AgentServerRecord) async throws -> [String: String] {
        guard isSignedIn else { throw AgentServerError.needsAuthentication }
        return ["Authorization": "Bearer fixture-account-token"]
    }
}
