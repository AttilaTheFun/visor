import Foundation

// Closing an agent's own (Logan, 25 Nov 2026: "agents may close pull
// requests and issues they opened themselves"): an issue or a pull request
// is closed only when its author is the GitHub App's bot, the one the
// gate's token is minted for (GitHubAppIdentity). Read with the same token
// as the close goes on with: REST's `user.login` (`<slug>[bot]`), or
// GraphQL's `author` (a Bot whose login is the slug). Anyone else's is
// refused; so is every close when the token isn't the App's (the auth
// token, or none), its bot unknown. Reopening, an agent's own included,
// stays Logan's (GitHubGate's REST and GraphQL rules).

extension GateChecker {
    /// Why a close is refused when the App's bot isn't known.
    static let noBot = "an agent closes only the issues and pull requests it opened itself, as the GitHub App's bot, "
        + "and with no GitHub App (github-app/key and github-app/id) or its bot not found, closing is Logan's"

    /// `PATCH …/issues/{n}` or `…/pulls/{n}` closing it: its author read
    /// from `GET …/issues/{n}` (a pull request is an issue there too).
    func close(_ repository: String, _ number: Int) async -> CheckOutcome {
        guard let bot else { return .refuse(Self.noBot) }
        let answer = await github.get("/repos/\(repository)/issues/\(number)")
        guard answer.ok else { return .fail("GitHub didn't give #\(number) of \(repository) (\(answer.status))") }
        let kind = answer["pull_request"] == nil ? "issue" : "pull request"
        guard let author = answer["user", "login"]?.string else { return .fail("GitHub gave \(kind) #\(number) of \(repository) no author") }
        guard author.lowercased() == bot.name.lowercased() else {
            return .refuse("\(kind) #\(number) of \(repository) is \(author)'s: an agent closes only what it opened itself (\(bot.name)'s)")
        }
        return .pass(nil)
    }

    /// `closeIssue` or `closePullRequest`: the node a `kind` in an allowed
    /// repository, its author the App's bot.
    func close(node id: String, kind: String) async -> CheckOutcome {
        guard let bot else { return .refuse(Self.noBot) }
        let answer = await github.graphQL("""
            query($id: ID!) { node(id: $id) { __typename \
            ... on Issue { number author { __typename login } repository { nameWithOwner } } \
            ... on PullRequest { number author { __typename login } repository { nameWithOwner } } } }
            """, variables: ["id": .string(id)])
        guard answer.ok, let found = answer["data"]?.object else { return .fail("GitHub didn't resolve \(id) (\(answer.status))") }
        guard let node = found["node"]?.object, let typename = node["__typename"]?.string else {
            return .refuse("\(id) is no node the agent proxy can see")
        }
        let named = kind == "PullRequest" ? "pull request" : "issue"
        guard typename == kind else { return .refuse("\(id) is a \(typename), not a \(kind)") }
        guard let repository = node["repository"]?.object?["nameWithOwner"]?.string else { return .fail("GitHub gave \(id) no repository") }
        guard rules.allows(repository) else {
            return .refuse("\(repository) is not among the repositories the agent proxy allows (\(rules.named))")
        }
        var number = ""
        if case .number(let digits)? = node["number"] { number = " #\(digits)" }
        // A Bot's login is its slug in GraphQL, `<slug>[bot]` in REST.
        let author = node["author"]?.object
        let login = author?["login"]?.string ?? ""
        let isBot = (author?["__typename"]?.string == "Bot" && login.lowercased() == bot.slug.lowercased())
            || login.lowercased() == bot.name.lowercased()
        guard isBot else {
            let whose = login.isEmpty ? "a deleted account's" : "\(login)'s"
            return .refuse("\(named)\(number) of \(repository) is \(whose): an agent closes only what it opened itself (\(bot.name)'s)")
        }
        return .pass(nil)
    }
}
