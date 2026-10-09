/// Signs in to the account's servers by the account: its headers on every
/// request, and a sign-in asked for when no one is signed in.
struct AccountAuthenticator: AgentServerAuthenticator {
    let id = VisorAccounts.authenticatorID
    let title = "Account"

    func headers(for record: AgentServerRecord) async throws -> [String: String] {
        guard let account = VisorAccounts.current, account.isSignedIn else { throw AgentServerError.needsAuthentication }
        return try await account.headers(for: record)
    }
}
