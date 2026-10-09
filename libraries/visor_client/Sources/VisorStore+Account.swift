import VisorServices

// The app's account (`VisorAccount`), where a fork has one: signed in, its
// servers are the store's, signed in to by it; signed out, they go, and
// the views show its sign-in.

extension VisorStore {
    /// At launch: the fixture's account if the setting asks for it, the
    /// account's authenticator registered, and its servers as it stands.
    func startAccount() {
        let asked = VisorHost.settings?.get(key: "account") ?? ""
        if VisorAccounts.current == nil, asked == "fixture" || asked == "fixture-signed-in" {
            AgentServerProviders.register(FixtureAgentServerProvider())
            VisorAccounts.current = FixtureAccount(signedIn: asked == "fixture-signed-in")
        }
        guard VisorAccounts.current != nil else { return }
        AgentServerAuthenticators.register(AccountAuthenticator())
        VisorAccounts.whenChanged { [weak self] in self?.accountChanged() }
        accountChanged()
    }

    /// Signs the account in and lists its servers; nil when signed in, else
    /// what went wrong.
    public func signInAccount() async -> String? {
        guard let account = VisorAccounts.current else { return nil }
        do {
            try await account.signIn()
        } catch {
            return "\(error)"
        }
        accountChanged()
        return nil
    }

    public func signOutAccount() {
        VisorAccounts.current?.signOut()
        accountChanged()
    }

    /// The account as it is now: signed in, its servers listed again (and
    /// those waiting for a sign-in connected); signed out, its servers gone.
    func accountChanged() {
        let signedIn = VisorAccounts.current?.isSignedIn ?? false
        accountSignedIn = signedIn
        guard signedIn else {
            for server in servers where server.record.fromAccount { remove(server) }
            return
        }
        Task { await refreshAccountServers() }
    }

    /// Takes in the servers the account lists: a new one added, one held
    /// brought up to date (and connected again if it was waiting for a
    /// sign-in), one no longer listed taken away. What the account cannot
    /// answer leaves them as they are.
    func refreshAccountServers() async {
        guard let account = VisorAccounts.current, account.isSignedIn,
              let listed = try? await account.servers(), accountSignedIn else { return }
        var kept: Set<String> = []
        for var record in listed {
            record.fromAccount = true
            record.authentication = VisorAccounts.authenticatorID
            // The account's names stand over what each server calls itself.
            if !record.name.isEmpty { record.renamed = true }
            let match: (AgentServerConnection) -> Bool = { held in
                held.record.fromAccount && (held.record.address == record.address
                    || (!record.serverID.isEmpty && held.record.serverID == record.serverID))
            }
            if let held = servers.first(where: match) {
                held.update { current in
                    current.address = record.address
                    if !record.name.isEmpty { current.name = record.name; current.renamed = true }
                    if current.serverID.isEmpty { current.serverID = record.serverID }
                }
                if held.state.wantsAuthentication { held.connect() }
                kept.insert(held.id)
            } else {
                let added = add(record)
                added.update { $0.fromAccount = true; $0.authentication = VisorAccounts.authenticatorID; $0.renamed = record.renamed }
                kept.insert(added.id)
            }
        }
        for server in servers where server.record.fromAccount && !kept.contains(server.id) { remove(server) }
    }
}
