import Foundation

/// Merging a pull request once CI is green, and bringing its branch up to
/// date first. Logan (2026-10-31): agents merge pull requests in his
/// repositories when CI is green; he checks quality when he reviews
/// releases. Every guard is gh_mcp's own, checked right before the merge,
/// and GitHub's rules (branch protection, rulesets, "up to date before
/// merging") hold as well: nothing here bypasses them.
enum MergeTools {
    /// The pull request, refused unless it is open and its head is a branch
    /// of the same repository (never a fork's).
    static func openSameRepositoryPull(_ repo: RepoName, _ number: Int, _ context: ToolContext) async throws -> JSON {
        let pull = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls/\(number)")
        if pull["merged"]?.boolValue == true { throw ToolError.refused("pull request #\(number) is already merged") }
        guard pull["state"]?.stringValue == "open" else {
            throw ToolError.refused("pull request #\(number) is \(pull["state"]?.stringValue ?? "not open")")
        }
        let head = pull["head"]?["repo"]?["full_name"]?.stringValue
        let base = pull["base"]?["repo"]?["full_name"]?.stringValue ?? repo.description
        guard let head, head.caseInsensitiveCompare(base) == .orderedSame else {
            throw ToolError.refused("pull request #\(number)'s head is \(head.map { "in \($0)" } ?? "in a deleted repository"), not a branch of \(base)")
        }
        guard Policy.isSHA(pull["head"]?["sha"]?.stringValue) else {
            throw ToolError.failed("GitHub gave pull request #\(number) no head SHA")
        }
        return pull
    }

    static func updateBranch(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let pull = try await openSameRepositoryPull(repo, number, context)
        let head = pull["head"]!["sha"]!.stringValue!
        let base = pull["base"]?["ref"]?.stringValue ?? "its base"
        let path = "/repos/\(repo)/pulls/\(number)/update-branch"
        let response = try await context.github.send(repo, "PUT", path, body: ["expected_head_sha": .string(head)])
        guard response.isSuccess else {
            // 422: the head moved since it was read, or there is nothing to
            // update (GitHub's message says which).
            let description = GitHub.describe(response, method: "PUT", path: path)
            if response.status == 422 { throw ToolError.refused(description) }
            throw ToolError.failed(description)
        }
        let answer = (try? JSON.parse(response.body)) ?? .null
        if let newHead = answer["sha"]?.stringValue ?? answer["head"]?["sha"]?.stringValue, Policy.isSHA(newHead) {
            return "Pull request #\(number) of \(repo) is up to date with \(base): its head is \(newHead)."
        }
        return "Pull request #\(number) of \(repo): updating its branch with \(base) (from \(head)); its checks run again on the new head."
    }

    static func merge(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let number = arguments.int("number")!
        let method = arguments.string("method") ?? "squash"
        let title = arguments.string("title"), message = arguments.string("message")
        if method == "rebase" && (title != nil || message != nil) {
            throw ToolError.invalid("a rebase makes no merge commit: title and message are for squash or merge")
        }

        // The pull request: open, not a draft, from a branch of this
        // repository, into its default branch.
        let pull = try await openSameRepositoryPull(repo, number, context)
        if pull["draft"]?.boolValue == true { throw ToolError.refused("pull request #\(number) is a draft") }
        let repository = try await context.github.json(repo, "GET", "/repos/\(repo)")
        guard let defaultBranch = repository["default_branch"]?.stringValue else {
            throw ToolError.failed("GitHub gave \(repo) no default branch")
        }
        let base = pull["base"]?["ref"]?.stringValue ?? ""
        guard base == defaultBranch else {
            throw ToolError.refused("pull request #\(number) is into \(base), not \(repo)'s default branch \(defaultBranch)")
        }
        let allowed = ["squash": "allow_squash_merge", "merge": "allow_merge_commit", "rebase": "allow_rebase_merge"]
        if repository[allowed[method]!]?.boolValue == false {
            throw ToolError.refused("\(repo) doesn't allow \(method) merges")
        }

        // GitHub's own rules: clean means up to date where that is required,
        // and the required checks and reviews in.
        let head = pull["head"]!["sha"]!.stringValue!
        switch pull["mergeable_state"]?.stringValue ?? "unknown" {
        case "clean":
            break
        case "behind":
            throw ToolError.refused("pull request #\(number) is behind \(base): call pr_update_branch, then merge once its checks pass again")
        case "unknown":
            throw ToolError.refused("GitHub is still working out whether pull request #\(number) can be merged; ask again in a few seconds")
        case let state:
            throw ToolError.refused("pull request #\(number) isn't clean to merge: GitHub's mergeable_state is \(state)")
        }

        // Every check on the head: at least one check run, every one
        // completed and passed, and every commit status a success where
        // they are readable.
        if let reason = try await checksRefusal(repo, head: head, context) {
            throw ToolError.refused("pull request #\(number)'s head \(head.prefix(12)): \(reason)")
        }

        // Protected files (CODEOWNERS on the base branch): only with an
        // owner's approval of this head, whatever GitHub's plan enforces.
        if let reason = try await ownersRefusal(repo, number: number, base: base, head: head, context) {
            throw ToolError.refused("pull request #\(number): \(reason)")
        }

        // The merge, of the head checked: a push since makes GitHub refuse it.
        var body: [String: JSON] = ["merge_method": .string(method), "sha": .string(head)]
        if let title { body["commit_title"] = .string(title) }
        if let message { body["commit_message"] = .string(message) }
        let path = "/repos/\(repo)/pulls/\(number)/merge"
        let response = try await context.github.send(repo, "PUT", path, body: .object(body))
        guard response.isSuccess else {
            let description = GitHub.describe(response, method: "PUT", path: path)
            switch response.status {
            case 409: throw ToolError.refused("pull request #\(number)'s head changed since it was checked: \(description)")
            case 405, 422: throw ToolError.refused(description)
            default: throw ToolError.failed(description)
            }
        }
        let answer = (try? JSON.parse(response.body)) ?? .null
        guard answer["merged"]?.boolValue == true, let sha = answer["sha"]?.stringValue else {
            throw ToolError.failed("GitHub answered the merge of #\(number) without merging it: \(Redact.line(answer.text()))")
        }
        return "Pull request #\(number) of \(repo) is merged into \(base) (\(method)): \(sha)."
    }

    /// nil if every check on `head` passed, else the first reason it
    /// didn't.
    static func checksRefusal(_ repo: RepoName, head: String, _ context: ToolContext) async throws -> String? {
        var runs: [JSON] = []
        var page = 1
        while true {
            let answer = try await context.github.json(repo, "GET", "/repos/\(repo)/commits/\(head)/check-runs",
                                                       query: ["per_page": "100", "page": String(page)])
            let some = answer["check_runs"]?.arrayValue ?? []
            runs += some
            let total = answer["total_count"]?.intValue ?? runs.count
            if some.count < 100 || runs.count >= total { break }
            page += 1
            if page > 10 { return "more than 1000 check runs; too many to check" }
        }
        guard !runs.isEmpty else { return "it has no check runs: nothing says CI passed" }
        for run in runs {
            let name = run["name"]?.stringValue ?? "a check run"
            if run["status"]?.stringValue != "completed" {
                return "\(name) is \(run["status"]?.stringValue ?? "pending")"
            }
            let conclusion = run["conclusion"]?.stringValue ?? "none"
            if !["success", "skipped", "neutral"].contains(conclusion) { return "\(name) concluded \(conclusion)" }
        }
        // Commit statuses need the app's statuses permission; where they
        // aren't readable, check runs alone decide (as `checks` does).
        let path = "/repos/\(repo)/commits/\(head)/status"
        let response = try await context.github.send(repo, "GET", path, query: ["per_page": "100"])
        if response.isSuccess {
            let status = (try? JSON.parse(response.body)) ?? .null
            for item in status["statuses"]?.arrayValue ?? [] {
                let state = item["state"]?.stringValue ?? "unknown"
                if state != "success" { return "status \(item["context"]?.stringValue ?? "?") is \(state)" }
            }
        } else if ![403, 404].contains(response.status) {
            throw ToolError.failed(GitHub.describe(response, method: "GET", path: path))
        }
        return nil
    }
}
