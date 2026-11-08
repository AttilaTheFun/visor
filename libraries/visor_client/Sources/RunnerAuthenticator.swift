/// Signs in to a Runner account's servers by its session
/// (docs/runner-accounts.md): the Runner's bearer on every request, which
/// it checks and replaces with the server's own before passing it on.
struct RunnerAuthenticator: AgentServerAuthenticator {
    static let name = "runner"
    let id = RunnerAuthenticator.name
    let title = "Visor Runner"

    func headers(for record: AgentServerRecord) async throws -> [String: String] {
        guard let id = record.account, let account = RunnerAccounts.account(id) else {
            throw AgentServerError.needsAuthentication
        }
        return try await account.headers(for: record)
    }
}
