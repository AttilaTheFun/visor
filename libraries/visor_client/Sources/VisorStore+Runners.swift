import VisorServices

// The Runners signed in to (RunnerAccount, docs/runner-accounts.md): each
// one's servers are the store's, signed in to by its session; signed out
// or removed, they go. Their records are told apart by `account`, the
// fork's one account's (VisorAccount) by having none.

extension VisorStore {
    /// At launch: the Runners kept, their authenticator, their servers.
    func startRunners() {
        AgentServerAuthenticators.register(RunnerAuthenticator())
        RunnerAccounts.load()
        runners = RunnerAccounts.all
        for account in RunnerAccounts.all { runnerChanged(account) }
    }

    /// The computers of no Runner signed in to: those added by hand, and
    /// the fork's account's.
    public var ownServers: [AgentServerConnection] {
        servers.filter { server in server.record.account.map { id in !runners.contains { $0.id == id } } ?? true }
    }

    /// A Runner's computers, as it lists them.
    public func servers(of account: RunnerAccount) -> [AgentServerConnection] {
        servers.filter { $0.record.account == account.id }
    }

    /// Signs in to a Runner at `url` as `username`, and adds its servers;
    /// nil when it did, else what went wrong. A Runner already held by URL
    /// and name is signed in to again.
    public func signInToRunner(url given: String, username: String, password: String) async -> String? {
        let url = RunnerAccounts.normalized(given)
        let account = RunnerAccounts.all.first { $0.url == url && $0.kept.username == username }
            ?? RunnerAccount(kept: RunnerAccount.Kept(id: AgentServerRecord.newID(), url: url, username: username, fingerprint: nil, expires: nil))
        do {
            try await account.signIn(password: password)
        } catch {
            return "\(error)"
        }
        RunnerAccounts.add(account)
        runners = RunnerAccounts.all
        runnerChanged(account)
        return nil
    }

    public func signOut(of account: RunnerAccount) {
        account.signOut()
        runnerChanged(account)
    }

    /// Signs out and forgets the Runner, and its servers.
    public func remove(_ account: RunnerAccount) {
        account.signOut()
        RunnerAccounts.remove(account.id)
        runners = RunnerAccounts.all
        for server in servers where server.record.account == account.id { remove(server) }
    }

    /// The account as it is now: signed in, its servers listed again;
    /// signed out, they go.
    func runnerChanged(_ account: RunnerAccount) {
        guard account.isSignedIn else {
            for server in servers where server.record.account == account.id { remove(server) }
            return
        }
        Task { await refreshRunnerServers(account) }
    }

    /// Takes in the servers a Runner lists: a new one added, one held
    /// brought up to date (and connected again if it was waiting for a
    /// sign-in), one no longer listed taken away. A session the Runner
    /// turned down signs the account out; anything else it can't answer
    /// leaves them as they are.
    func refreshRunnerServers(_ account: RunnerAccount) async {
        let listed: [AgentServerRecord]
        do {
            listed = try await account.servers()
        } catch AgentServerError.needsAuthentication {
            runnerChanged(account)
            return
        } catch {
            return
        }
        var kept: Set<String> = []
        for record in listed {
            if let held = servers.first(where: { $0.record.account == account.id && $0.record.address == record.address }) {
                held.update { current in
                    current.name = record.name
                    current.renamed = true
                }
                if held.state.wantsAuthentication { held.connect() }
                kept.insert(held.id)
            } else {
                let added = add(record)
                added.update { current in
                    current.fromAccount = true
                    current.account = account.id
                    current.authentication = RunnerAuthenticator.name
                    current.renamed = true
                }
                kept.insert(added.id)
            }
        }
        for server in servers where server.record.account == account.id && !kept.contains(server.id) { remove(server) }
    }
}
