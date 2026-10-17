import VisorProtocol

// An agent's account, asked for when it is about to be shown (the
// inspector): its limits move while no session of it runs (OpenAI resets
// Codex's now and then), and the server otherwise hears of them only from
// a turn.
extension AgentServerConnection {
    /// Asks the server how the agent's account stands now; what it says
    /// replaces the catalog's.
    public func refreshAccount(_ agent: AgentKind) {
        let server = server
        Task { [weak self] in
            guard let account = try? await server.account(of: agent), let self,
                  let index = self.catalogs.firstIndex(where: { $0.agent == agent }) else { return }
            self.catalogs[index].account = account
        }
    }
}
