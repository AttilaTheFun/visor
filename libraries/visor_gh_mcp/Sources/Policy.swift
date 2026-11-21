import Foundation

/// What gh_mcp may and may not do on GitHub, in one place.
///
/// Every request any tool makes passes `check` first (GitHub.send calls
/// it): reads anywhere in the repository named, writes only those listed
/// in `writes`, each with the fields it may carry. Everything else is
/// refused, whatever a tool asks for.
public enum Policy {
    /// Never, through any tool: what goes through Logan.
    public static let never = [
        "merge a pull request any way but pr_merge's: into anything but the default branch, from a fork, before GitHub's rules and every check pass, bypassing them (admin), or by GraphQL",
        "close or reopen a pull request or an issue",
        "approve a pull request or request changes (reviews are COMMENT only)",
        "delete anything: branches, tags, comments, reviews, releases, issues, files",
        "push main, master, a repository's default branch or a tag; force without a lease",
        "create a tag, publish a release, or edit a published one",
        "change settings, collaborators, branch protection, rulesets, webhooks, deploy keys, secrets, variables or environments",
        "re-run, dispatch or cancel a workflow run any way but run_rerun's, run_dispatch's and run_cancel's (no old commit's run, no release's or schedule's re-run, no dispatch on a tag or another repository's branch, no release's cancel, no force-cancel); delete runs or logs, approve a fork's runs, or change Actions' settings",
        "touch a repository outside the config's repositories",
    ]

    /// Never pushed, whatever the repository's default branch is (which is
    /// never pushed either).
    public static let protectedBranches = ["main", "master"]

    /// A write gh_mcp makes: a method, a path (`{owner}/{repo}` the
    /// repository named, `{n}` a number), the fields its body may carry, and
    /// what those fields must say.
    struct Write: Sendable {
        let method: String
        let path: String
        let fields: Set<String>
        var rule: (@Sendable (JSON) -> String?)? = nil
    }

    static let writes: [Write] = [
        Write(method: "POST", path: "/repos/{owner}/{repo}/pulls", fields: ["title", "head", "base", "body", "draft"]),
        Write(method: "PATCH", path: "/repos/{owner}/{repo}/pulls/{n}", fields: ["title", "body"]),
        Write(method: "POST", path: "/repos/{owner}/{repo}/pulls/{n}/comments/{n}/replies", fields: ["body"]),
        Write(method: "POST", path: "/repos/{owner}/{repo}/pulls/{n}/reviews", fields: ["body", "event", "commit_id"]) { body in
            body["event"]?.stringValue == "COMMENT" ? nil : "a review is COMMENT only; approving and requesting changes are Logan's"
        },
        Write(method: "POST", path: "/repos/{owner}/{repo}/issues", fields: ["title", "body", "labels"]),
        Write(method: "PATCH", path: "/repos/{owner}/{repo}/issues/{n}", fields: ["title", "body", "labels"]),
        Write(method: "POST", path: "/repos/{owner}/{repo}/issues/{n}/comments", fields: ["body"]),
        Write(method: "POST", path: "/repos/{owner}/{repo}/releases", fields: ["tag_name", "target_commitish", "name", "body", "draft"]) { body in
            body["draft"]?.boolValue == true ? nil : "a release is made as a draft only"
        },
        // Only fields a draft's edit needs: never `draft`, `prerelease` or
        // `make_latest`. `tag_name` is the draft's own, sent back unchanged
        // (GitHub resets a draft's tag a PATCH leaves out); a draft's tag
        // publishes nothing. (release_edit_draft checks first that the
        // release is a draft.)
        Write(method: "PATCH", path: "/repos/{owner}/{repo}/releases/{n}", fields: ["name", "body", "target_commitish", "tag_name"]),
        // A merge, pr_merge's only: the head it checked (`sha`, so a push
        // in between makes GitHub refuse it) and a method. pr_merge checks
        // the rest (open, not a draft, the default branch, no fork, GitHub's
        // mergeable_state clean, every check green) right before sending it.
        Write(method: "PUT", path: "/repos/{owner}/{repo}/pulls/{n}/merge", fields: ["merge_method", "sha", "commit_title", "commit_message"]) { body in
            guard isSHA(body["sha"]?.stringValue) else { return "a merge names the head it checked (sha)" }
            guard ["squash", "merge", "rebase"].contains(body["merge_method"]?.stringValue ?? "") else {
                return "a merge names its method: squash, merge or rebase"
            }
            return nil
        },
        // The base merged into a pull request's branch (pr_update_branch),
        // only while its head is still the one named.
        Write(method: "PUT", path: "/repos/{owner}/{repo}/pulls/{n}/update-branch", fields: ["expected_head_sha"]) { body in
            isSHA(body["expected_head_sha"]?.stringValue) ? nil : "an update names the head it expects (expected_head_sha)"
        },
        // A run's jobs again (run_rerun: a completed pull_request or push
        // run whose commit is still its branch's head), and a run cancelled
        // (run_cancel: still going, not a release's). No body: not
        // `enable_debug_logging`. Never /force-cancel,
        // DELETE …/runs/{n} or …/logs, /approve, or …/actions/permissions.
        Write(method: "POST", path: "/repos/{owner}/{repo}/actions/runs/{n}/rerun", fields: []),
        Write(method: "POST", path: "/repos/{owner}/{repo}/actions/runs/{n}/rerun-failed-jobs", fields: []),
        Write(method: "POST", path: "/repos/{owner}/{repo}/actions/runs/{n}/cancel", fields: []),
        // A workflow dispatched (run_dispatch): on a branch (never a tag or a
        // full ref), with inputs; the workflow by its numeric id.
        Write(method: "POST", path: "/repos/{owner}/{repo}/actions/workflows/{n}/dispatches", fields: ["ref", "inputs"]) { body in
            guard let ref = body["ref"]?.stringValue, !ref.isEmpty, !ref.hasPrefix("refs/") else { return "a dispatch names a branch (ref)" }
            return nil
        },
        // A pull request to draft and back: GraphQL's only, these two
        // mutations exactly.
        Write(method: "POST", path: "/graphql", fields: ["query", "variables"]) { body in
            readyMutations.contains(body["query"]?.stringValue ?? "") ? nil : "the only GraphQL gh_mcp sends is ready-for-review and back to draft"
        },
    ]

    static let readyMutations = [
        "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { number isDraft } } }",
        "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { number isDraft } } }",
    ]

    /// A commit's full SHA: 40 hex digits (SHA-1) or 64 (SHA-256).
    static func isSHA(_ text: String?) -> Bool {
        guard let text, text.count == 40 || text.count == 64 else { return false }
        return text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// nil if gh_mcp may send `request` for `repo`, else why not.
    public static func refusal(_ request: GitHubRequest, repo: RepoName) -> String? {
        var path = request.path
        if path.hasPrefix("https://api.github.com") { path.removeFirst("https://api.github.com".count) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if request.method == "GET" {
            if matches(path, "/repos/{owner}/{repo}", repo, prefix: true) { return nil }
            // A renamed repository's redirect.
            if path.hasPrefix("/repositories/") { return nil }
            return "GET \(path) is outside \(repo)"
        }
        guard let write = writes.first(where: { $0.method == request.method && matches(path, $0.path, repo, prefix: false) }) else {
            return "\(request.method) \(path) is not among the writes gh_mcp makes"
        }
        let body = request.body ?? .object([:])
        let extra = Set(body.objectValue?.keys.map { $0 } ?? []).subtracting(write.fields)
        if !extra.isEmpty { return "\(request.method) \(path) never sends \(extra.sorted().joined(separator: ", "))" }
        return write.rule?(body)
    }

    /// `path` against a template; with `prefix`, the template or anything
    /// under it.
    static func matches(_ path: String, _ template: String, _ repo: RepoName, prefix: Bool) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let pattern = template.split(separator: "/", omittingEmptySubsequences: false)
        guard prefix ? parts.count >= pattern.count : parts.count == pattern.count else { return false }
        for (part, expected) in zip(parts, pattern) {
            switch expected {
            case "{owner}": if part.caseInsensitiveCompare(repo.owner) != .orderedSame { return false }
            case "{repo}": if part.caseInsensitiveCompare(repo.name) != .orderedSame { return false }
            case "{n}": if part.isEmpty || !part.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
            default: if part != expected { return false }
            }
        }
        return true
    }
}
