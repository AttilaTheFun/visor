import Foundation

// The merge's checks (docs/github-gate-rules.md, §2.7): [M1]-[M4] for an open
// pull request between two branches of one repository, then [M6]-[M12] for
// a merge, and the SHA it merges the head that was checked ([M13]).

extension GateChecker {
    /// The pull request, open and from a branch of its own repository
    /// ([M1]-[M4]), or why not.
    func openPull(_ repository: String, _ number: Int) async -> Result<GitHubAnswer, CheckOutcome> {
        let answer = await github.get("/repos/\(repository)/pulls/\(number)")
        guard answer.ok else { return .failure(.fail("GitHub didn't give pull request #\(number) of \(repository) (\(answer.status))")) }
        if answer["merged"]?.bool == true { return .failure(.refuse("pull request #\(number) is already merged")) }
        guard answer["state"]?.string == "open" else {
            return .failure(.refuse("pull request #\(number) is \(answer["state"]?.string ?? "not open")"))
        }
        let base = answer["base", "repo", "full_name"]?.string ?? repository
        guard let head = answer["head", "repo", "full_name"]?.string else {
            return .failure(.refuse("pull request #\(number)'s head is in a deleted repository, not a branch of \(base)"))
        }
        guard head.lowercased() == base.lowercased() else {
            return .failure(.refuse("pull request #\(number)'s head is in \(head), not a branch of \(base)"))
        }
        guard let sha = answer["head", "sha"]?.string, GitRefName.isSHA(sha) else {
            return .failure(.fail("GitHub gave pull request #\(number) no head SHA"))
        }
        return .success(answer)
    }

    /// [U1]: an update-branch's pull request; the pinned head is GitHub's own
    /// check ([U2]).
    func pullToUpdate(_ repository: String, _ number: Int) async -> CheckOutcome {
        switch await openPull(repository, number) {
        case .failure(let outcome): return outcome
        case .success: return .pass(nil)
        }
    }

    /// A pull request's node, resolved to its repository (allowed) and
    /// number.
    func pullRequest(node id: String) async -> Result<(String, Int), CheckOutcome> {
        let answer = await github.graphQL("query($id: ID!) { node(id: $id) { __typename ... on PullRequest { number repository { nameWithOwner } } } }",
                                          variables: ["id": .string(id)])
        guard answer.ok, let node = answer["data", "node"]?.object else { return .failure(.fail("GitHub didn't resolve \(id) (\(answer.status))")) }
        guard node["__typename"]?.string == "PullRequest", case .number(let digits)? = node["number"], let number = Int(digits),
              let repository = node["repository"]?.object?["nameWithOwner"]?.string else {
            return .failure(.refuse("\(id) is not a pull request"))
        }
        guard rules.allows(repository) else {
            return .failure(.refuse("\(repository) is not among the repositories Visor's proxy allows (\(rules.named))"))
        }
        return .success((repository, number))
    }

    func graphQLMerge(_ id: String, method: String, variable: String?, expected: String?) async -> CheckOutcome {
        guard let variable else {
            return .refuse("a merge by GraphQL gives its input as a variable ($input), as gh does, so the proxy can pin the head it checked")
        }
        switch await pullRequest(node: id) {
        case .failure(let outcome):
            return outcome
        case .success(let (repository, number)):
            let checked = await merge(repository, number, sha: expected, method: method)
            guard case .pass = checked else { return checked }
            // The head the checks read, pinned: GitHub refuses the merge if it
            // moved since.
            let head = await github.get("/repos/\(repository)/pulls/\(number)")["head", "sha"]?.string ?? ""
            guard GitRefName.isSHA(head) else { return .fail("GitHub gave pull request #\(number) no head SHA") }
            return .pass(.variableField(variable: variable, field: "expectedHeadOid", value: .string(head)))
        }
    }

    /// [M1]-[M13]: `sha` the head they read (nil: the head read is the one
    /// pinned, as gh pr merge's is).
    func merge(_ repository: String, _ number: Int, sha: String?, method: String) async -> CheckOutcome {
        let pull: GitHubAnswer
        switch await openPull(repository, number) {
        case .failure(let outcome): return outcome
        case .success(let answer): pull = answer
        }
        let head = pull["head", "sha"]?.string ?? ""
        if let sha, sha.lowercased() != head.lowercased() {
            return .refuse("pull request #\(number)'s head is \(Self.short(head)), not the \(Self.short(sha)) the merge names: check it again")
        }
        if pull["draft"]?.bool == true { return .refuse("pull request #\(number) is a draft") }
        let repo = await github.get("/repos/\(repository)")
        guard repo.ok, let defaultBranch = repo["default_branch"]?.string else { return .fail("GitHub gave \(repository) no default branch") }
        let base = pull["base", "ref"]?.string ?? ""
        guard base == defaultBranch else {
            return .refuse("pull request #\(number) is into \(base), not \(repository)'s default branch \(defaultBranch)")
        }
        let allowed = ["squash": "allow_squash_merge", "merge": "allow_merge_commit", "rebase": "allow_rebase_merge"][method] ?? ""
        if repo[allowed]?.bool == false { return .refuse("\(repository) doesn't allow \(method) merges") }
        switch pull["mergeable_state"]?.string ?? "unknown" {
        case "clean":
            break
        case "behind":
            return .refuse("pull request #\(number) is behind \(base): update its branch, then merge once its checks pass again")
        case "unknown":
            return .refuse("GitHub is still working out whether pull request #\(number) can be merged; ask again in a few seconds")
        case let state:
            return .refuse("pull request #\(number) isn't clean to merge: GitHub's mergeable_state is \(state)")
        }
        if let reason = await failingChecks(repository, head) {
            return .refuse("pull request #\(number)'s head \(Self.short(head)): \(reason)")
        }
        if rules.merge.codeOwners {
            switch await codeOwnersApproval(repository, number, base: base, head: head) {
            case .failure(let outcome): return outcome
            case .success: break
            }
        }
        return .pass(nil)
    }

    /// [M11]: why the head's checks haven't passed, if they haven't: every
    /// check run completed and passing, and every readable status success.
    private func failingChecks(_ repository: String, _ head: String) async -> String? {
        var runs: [[String: GateJSON]] = []
        for page in 1...11 {
            if page == 11 { return "more than 1000 check runs; too many to check" }
            let answer = await github.get("/repos/\(repository)/commits/\(head)/check-runs?per_page=100&page=\(page)")
            guard answer.ok else { return "GitHub didn't give its check runs (\(answer.status))" }
            let listed = answer["check_runs"]?.array?.compactMap(\.object) ?? []
            runs += listed
            var total = 0
            if case .number(let digits)? = answer["total_count"] { total = Int(digits) ?? 0 }
            if listed.count < 100 || runs.count >= total { break }
        }
        guard !runs.isEmpty else { return "it has no check runs: nothing says CI passed" }
        for run in runs {
            let name = run["name"]?.string ?? "a check"
            let status = run["status"]?.string ?? "unknown"
            guard status == "completed" else { return "\(name) is \(status)" }
            let conclusion = run["conclusion"]?.string ?? "unknown"
            guard rules.merge.passingConclusions.contains(conclusion) else { return "\(name) concluded \(conclusion)" }
        }
        let statuses = await github.get("/repos/\(repository)/commits/\(head)/status?per_page=100")
        if statuses.ok {
            for status in statuses["statuses"]?.array?.compactMap(\.object) ?? [] where status["state"]?.string != "success" {
                return "status \(status["context"]?.string ?? "?") is \(status["state"]?.string ?? "unknown")"
            }
        } else if statuses.status != 403, statuses.status != 404 {
            return "GitHub didn't give its statuses (\(statuses.status))"
        }
        return nil
    }

    /// [M12]: every changed path that CODEOWNERS on the base branch owns has
    /// an owner's approval of the head.
    private func codeOwnersApproval(_ repository: String, _ number: Int, base: String, head: String) async -> Result<Void, CheckOutcome> {
        var file: String?
        for path in [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"] {
            let answer = await github.get("/repos/\(repository)/contents/\(path)?ref=\(Self.encoded(base))")
            if answer.status == 404 { continue }
            guard answer.ok, let encoded = answer["content"]?.string,
                  let data = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
                  let text = String(data: data, encoding: .utf8) else {
                return .failure(.fail("\(repository)'s \(path) can't be read"))
            }
            file = text
            break
        }
        guard let file else { return .success(()) }
        let owners = CodeOwners(file)
        var changed: [String] = []
        for page in 1...31 {
            if page == 31 { return .failure(.refuse("pull request #\(number): it changes more than 3000 files, too many to check against CODEOWNERS")) }
            let answer = await github.get("/repos/\(repository)/pulls/\(number)/files?per_page=100&page=\(page)")
            guard answer.ok, let files = answer.json?.array else { return .failure(.fail("GitHub didn't give pull request #\(number)'s files")) }
            for file in files.compactMap(\.object) {
                if let name = file["filename"]?.string { changed.append(name) }
                if let previous = file["previous_filename"]?.string { changed.append(previous) }
            }
            if files.count < 100 { break }
        }
        let owned = changed.map { ($0, owners.owners(of: $0)) }.filter { !$0.1.isEmpty }
        guard !owned.isEmpty else { return .success(()) }
        // Each reviewer's latest review that says something.
        var latest: [String: (state: String, commit: String)] = [:]
        for page in 1...10 {
            let answer = await github.get("/repos/\(repository)/pulls/\(number)/reviews?per_page=100&page=\(page)")
            guard answer.ok, let reviews = answer.json?.array else { return .failure(.fail("GitHub didn't give pull request #\(number)'s reviews")) }
            for review in reviews.compactMap(\.object) {
                guard let login = review["user"]?.object?["login"]?.string?.lowercased(), let state = review["state"]?.string,
                      state != "COMMENTED", state != "PENDING" else { continue }
                latest[login] = (state, review["commit_id"]?.string ?? "")
            }
            if reviews.count < 100 { break }
        }
        var unapproved: [String] = []
        var needed: Set<String> = []
        for (path, pathOwners) in owned {
            let approved = pathOwners.contains { owner in
                guard owner.hasPrefix("@"), !owner.contains("/") else { return false }
                let login = String(owner.dropFirst()).lowercased()
                return latest[login].map { $0.state == "APPROVED" && $0.commit == head } ?? false
            }
            if !approved {
                unapproved.append(path)
                needed.formUnion(pathOwners)
            }
        }
        guard !unapproved.isEmpty else { return .success(()) }
        let listed = unapproved.prefix(5).joined(separator: ", ") + (unapproved.count > 5 ? " and \(unapproved.count - 5) more" : "")
        return .failure(.refuse("pull request #\(number): it changes protected files (\(listed)) and \(needed.sorted().joined(separator: ", ")) hasn't approved its head: those need their review"))
    }
}
