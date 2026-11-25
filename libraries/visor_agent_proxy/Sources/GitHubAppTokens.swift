// The GitHub App's installation tokens, minted here: the gate's token when
// the App's key and id are kept (Logan approved it for 0.71.1: container
// agents act as logan-shire-agent, never as him). A choice beside Settings'
// auth token (PreferredGitHubToken), so the rule of 19 Nov 2026 holds: no
// hard dependency on his GitHub Apps. Shireworks' GitHubAppTokens, back as
// an option.
//
// With the App's JWT (GitHubAppJWT), its installation is found by the gate's
// owner (`GET /app/installations`, the one whose account's login is the
// owner's, case aside) unless `github-app/installation` names it, and kept;
// that installation's token is minted (`POST
// /app/installations/{id}/access_tokens`) for the gate's repositories and
// with its permissions (GateRules' tokenRepositories and tokenPermissions),
// and kept until five minutes before it expires. A request that comes while
// one is minted waits for that one: a mint for each need, never one for each
// request. The secrets changed (the host reads them at most once a minute),
// everything found and minted for the old ones is forgotten.
//
// The App's bot is the container agents' git identity (0.72.1:
// GitHubAppIdentity): its slug from `GET /app`, with the JWT, and its bot
// user's id from `GET /users/<slug>%5Bbot%5D`, with an installation token.
// Found at the start and kept for the secrets, as the installation is;
// asked together, found once. One that couldn't be found is looked for
// again at the next asking.
//
// Said in the log: the App, its installation and what it reaches, at the
// start and when the secrets change; its bot's name and address, once
// found; each mint, with when it expires; each failure, once until it
// changes, and why there's no git identity, once until that changes. Never
// the key, the JWT or a token.

import Foundation
import _CryptoExtras

actor GitHubAppTokens {
    /// Why there's no token: said in the log, and in the request's refusal.
    struct Failure: Error, CustomStringConvertible, Equatable {
        /// What went wrong, as the log says it.
        let why: String
        var description: String { "agent-proxy has no auth token for GitHub: \(why)" }
    }

    /// A token is minted again once it has this little left.
    static let refreshBefore: TimeInterval = 5 * 60

    let rules: GateRules
    private let api: any GitHubAppCalling
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    /// The secrets what's below is for: other secrets, it's forgotten.
    private var seen: GitHubAppSecrets?
    /// Counted up as the secrets change: a mint for older ones keeps nothing.
    private var generation = 0
    private var key: _RSA.Signing.PrivateKey?
    private var installation: Int?
    private var held: (token: String, expires: Date)?
    private var minting: Task<String, any Error>?
    /// The App's bot, once found for these secrets, and its finding.
    private var bot: GitHubAppIdentity?
    private var findingBot: Task<GitHubAppIdentity, any Error>?
    /// Why there's no git identity, as last said.
    private var lastNoIdentity: String?
    /// The App's line said for these secrets.
    private var announced = false
    /// The last failure said, so a broken key isn't said at each request.
    private var lastFailure: String?

    init(rules: GateRules, api: any GitHubAppCalling = GitHubAppAPI(), now: @escaping @Sendable () -> Date = { Date() },
         log: @escaping @Sendable (String) -> Void) {
        self.rules = rules
        self.api = api
        self.now = now
        self.log = log
    }

    /// An installation token: the one kept while it has more than five
    /// minutes left, else the one being minted, else a new one.
    func token(_ secrets: GitHubAppSecrets) async throws -> String {
        adopt(secrets)
        if let held, held.expires.timeIntervalSince(now()) > Self.refreshBefore { return held.token }
        if let minting { return try await minting.value }
        let generation = self.generation
        let task = Task { try await self.mint(secrets, generation: generation) }
        minting = task
        return try await task.value
    }

    /// At the start: the key read and the installation found, so the App's
    /// line (or what's wrong) is in the log before the first request.
    func prepare(_ secrets: GitHubAppSecrets) async {
        adopt(secrets)
        // What's wrong is said in the log.
        _ = try? await installationID(secrets, key: signingKey(secrets), generation: generation)
        // The bot's line, or why there's none, said now too.
        _ = await identity(secrets)
    }

    /// The App's bot, as the container agents' git identity: the one kept
    /// for these secrets, else the one being found, else found now. Nil
    /// without the App (`secrets` nil: its key or its id isn't kept) or
    /// when it couldn't be found, each said once.
    func identity(_ secrets: GitHubAppSecrets?) async -> GitHubAppIdentity? {
        guard let secrets else {
            noIdentity("no GitHub App (github-app/key and github-app/id)")
            return nil
        }
        adopt(secrets)
        if let bot { return bot }
        let task: Task<GitHubAppIdentity, any Error>
        if let findingBot {
            task = findingBot
        } else {
            let generation = self.generation
            task = Task { try await self.findBot(secrets, generation: generation) }
            findingBot = task
        }
        do {
            return try await task.value
        } catch {
            noIdentity((error as? Failure)?.why ?? "\(error)")
            return nil
        }
    }

    /// GitHub turned the token down: the next request mints another.
    func forget() {
        held = nil
    }

    /// `secrets`, taken: when they aren't the ones before, all that was
    /// found and minted with those is forgotten.
    private func adopt(_ secrets: GitHubAppSecrets) {
        guard secrets != seen else { return }
        seen = secrets
        generation += 1
        key = nil
        installation = nil
        held = nil
        minting = nil
        bot = nil
        findingBot = nil
        lastNoIdentity = nil
        announced = false
        lastFailure = nil
    }

    /// Why the container agents have no git identity, said unless it was
    /// the last said.
    private func noIdentity(_ why: String) {
        guard why != lastNoIdentity else { return }
        lastNoIdentity = why
        log("github: no git identity for container agents: \(why)")
    }

    /// The App's slug (as the App, with its JWT), then its bot user's id
    /// (with an installation token): kept for these secrets, and said.
    /// What goes wrong in GitHub's answers is said by `identity`, once.
    private func findBot(_ secrets: GitHubAppSecrets, generation: Int) async throws -> GitHubAppIdentity {
        defer { if self.generation == generation { findingBot = nil } }
        let key = try signingKey(secrets)
        let app = try await call("GET", "/app", secrets: secrets, key: key, body: nil)
        guard (200..<300).contains(app.status) else {
            throw Failure(why: "GitHub answered \(app.status) for the App (GET /app): \(Self.message(app.body))")
        }
        struct App: Decodable { let slug: String }
        guard let slug = (try? JSONDecoder().decode(App.self, from: app.body))?.slug, GitHubAppIdentity.isSlug(slug) else {
            throw Failure(why: "GitHub answered \(app.status) for the App (GET /app), with no slug in it")
        }
        let token = try await self.token(secrets)
        let path = GitHubAppIdentity.userPath(slug: slug)
        let user: (status: Int, body: Data)
        do {
            user = try await api.read(path, token: token)
        } catch {
            throw Failure(why: "GitHub didn't answer (GET /users/\(slug)[bot]): \(error.localizedDescription)")
        }
        guard (200..<300).contains(user.status) else {
            // GitHub turned the token down: the next request mints another.
            if user.status == 401, self.generation == generation { held = nil }
            throw Failure(why: "GitHub answered \(user.status) for the App's bot user (GET /users/\(slug)[bot]): \(Self.message(user.body))")
        }
        struct User: Decodable { let id: Int }
        guard let id = (try? JSONDecoder().decode(User.self, from: user.body))?.id else {
            throw Failure(why: "GitHub answered \(user.status) for the App's bot user (GET /users/\(slug)[bot]), with no id in it")
        }
        let found = GitHubAppIdentity(slug: slug, userID: id)
        // Secrets changed meanwhile: this one is the asker's, and kept for none.
        guard self.generation == generation else { return found }
        bot = found
        lastNoIdentity = nil
        log("github: commits as \(found.name) \(found.email)")
        return found
    }

    private func mint(_ secrets: GitHubAppSecrets, generation: Int) async throws -> String {
        defer { if self.generation == generation { minting = nil } }
        let key = try signingKey(secrets)
        let installation = try await installationID(secrets, key: key, generation: generation)
        var body: [String: Any] = ["permissions": rules.tokenPermissions]
        if let repositories = rules.tokenRepositories(owner: rules.owner) { body["repositories"] = repositories }
        let answer = try await call("POST", "/app/installations/\(installation)/access_tokens", secrets: secrets, key: key,
                                    body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        guard (200..<300).contains(answer.status) else {
            // An installation found that is gone: found again next time.
            if answer.status == 404, secrets.installation == nil, self.generation == generation { self.installation = nil }
            throw failure("GitHub answered \(answer.status) minting a token: \(Self.message(answer.body))")
        }
        struct Minted: Decodable {
            let token: String
            let expires_at: String
        }
        // Its body is the token's: never said, whatever it holds.
        guard let minted = try? JSONDecoder().decode(Minted.self, from: answer.body), !minted.token.isEmpty,
              let expires = ISO8601DateFormatter().date(from: minted.expires_at) else {
            throw failure("GitHub answered \(answer.status) minting a token, with no token and expiry in it")
        }
        // Secrets changed meanwhile: this one is the request's, and kept for none.
        guard self.generation == generation else { return minted.token }
        held = (minted.token, expires)
        lastFailure = nil
        log("github: an installation token minted (expires \(ISO8601DateFormatter().string(from: expires)))")
        return minted.token
    }

    /// The App's key, read from its PEM once for these secrets.
    private func signingKey(_ secrets: GitHubAppSecrets) throws -> _RSA.Signing.PrivateKey {
        if let key { return key }
        guard let read = GitHubAppJWT.key(pem: secrets.key) else { throw failure("the App's key isn't a PEM") }
        key = read
        return read
    }

    /// The App's installation for the gate's owner: the one the secrets name,
    /// else the one GitHub lists for the owner. Kept, and said the first time.
    private func installationID(_ secrets: GitHubAppSecrets, key: _RSA.Signing.PrivateKey, generation: Int) async throws -> Int {
        if let installation { return installation }
        let found: Int
        if let named = secrets.installation {
            guard let number = Int(named) else { throw failure("the App's installation (github-app/installation) isn't a number") }
            found = number
        } else {
            guard let owner = rules.owner else { throw failure("no installation of the App for an owner: the gate's rules name no repository") }
            found = try await discover(owner, secrets: secrets, key: key)
        }
        guard self.generation == generation else { return found }
        installation = found
        if !announced {
            announced = true
            let owner = rules.owner
            let reached = rules.tokenRepositories(owner: owner)?.joined(separator: ", ")
                ?? owner.map { "all of \($0)'s" } ?? "all the installation's"
            log("github: tokens minted as the GitHub App \(secrets.id) (installation \(found)\(owner.map { " of \($0)" } ?? "")), hourly, for \(reached)")
        }
        return found
    }

    /// The installation whose account is `owner`, from the App's
    /// installations, a hundred at a time.
    private func discover(_ owner: String, secrets: GitHubAppSecrets, key: _RSA.Signing.PrivateKey) async throws -> Int {
        struct Listed: Decodable {
            struct Account: Decodable { let login: String }
            let id: Int
            let account: Account?
        }
        for page in 1...10 {
            let answer = try await call("GET", "/app/installations?per_page=100&page=\(page)", secrets: secrets, key: key, body: nil)
            guard (200..<300).contains(answer.status) else {
                throw failure("GitHub answered \(answer.status) listing the App's installations: \(Self.message(answer.body))")
            }
            guard let listed = try? JSONDecoder().decode([Listed].self, from: answer.body) else {
                throw failure("GitHub answered \(answer.status) listing the App's installations, with no list")
            }
            if let match = listed.first(where: { $0.account?.login.lowercased() == owner.lowercased() }) { return match.id }
            if listed.count < 100 { break }
        }
        throw failure("no installation of the App for \(owner)")
    }

    /// A call as the App, with a JWT made for it.
    private func call(_ method: String, _ path: String, secrets: GitHubAppSecrets, key: _RSA.Signing.PrivateKey,
                      body: Data?) async throws -> (status: Int, body: Data) {
        let jwt: String
        do {
            jwt = try GitHubAppJWT.make(appID: secrets.id, key: key, now: now())
        } catch {
            throw failure("the App's key couldn't sign its JWT")
        }
        do {
            return try await api.call(method, path, jwt: jwt, body: body)
        } catch {
            throw failure("GitHub didn't answer (\(method) \(path.split(separator: "?").first ?? "")): \(error.localizedDescription)")
        }
    }

    /// `why`, said in the log unless it was the last said, as the refusal.
    private func failure(_ why: String) -> Failure {
        if why != lastFailure {
            lastFailure = why
            log("github: \(why)")
        }
        return Failure(why: why)
    }

    /// GitHub's message in an error's body, else its first line (an error's
    /// body holds no token).
    static func message(_ body: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let message = object["message"] as? String {
            return message
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return text.isEmpty ? "no message" : text
    }
}
