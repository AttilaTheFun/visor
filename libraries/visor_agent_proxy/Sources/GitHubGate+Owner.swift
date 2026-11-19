// What is Logan's alone (Logan, 2026-11-14, as GitHub moved into agent-proxy):
// agents never merge a pull request, never publish a release and never
// delete a branch or any other ref, by any of GitHub's ways of doing it.
// Each is refused before anything else of the request is read, in the
// client's own form (GitHubInterceptor.refusal), and the gate's rules
// (gate.json) can't turn them back on.
//
// - Merging: REST's `PUT /repos/*/pulls/*/merge` (any write there) and
//   `POST /repos/*/merges`; GraphQL's `mergePullRequest`, `mergeBranch`,
//   `enablePullRequestAutoMerge` and `enqueuePullRequest`.
// - Publishing: a release made (POST) other than as a draft, or edited
//   (PATCH) with `draft: false`.
// - Deleting refs: REST's `DELETE /repos/*/git/refs/*`; GraphQL's
//   `deleteRef`; a push that updates a ref to the zero commit
//   (GitPushCommands' commands, read before the pack goes on).
//
// MultiPass let a merge through once its checks passed (GateChecker+Merge,
// kept for update-branch's checks); it refused the rest too, in other words.

extension GitHubGate {
    /// The refusals, in words that say whose each is.
    enum Owner {
        static func merging(_ what: String) -> String {
            "merging pull requests is Logan's alone, never an agent's (\(what)): leave the pull request open for him to merge"
        }

        static let publishing = "publishing a release is Logan's alone, never an agent's: a release is made and edited as a draft only (draft: true)"

        static func deleting(_ what: String) -> String {
            "deleting a branch or any other ref is Logan's alone, never an agent's (\(what))"
        }

        /// GraphQL's mutations that merge.
        static let mergingMutations: Set<String> = ["mergePullRequest", "mergeBranch", "enablePullRequestAutoMerge", "enqueuePullRequest"]
    }

    /// Why a REST request is Logan's alone, by its method and path; nil for
    /// any other.
    static func logansAlone(_ method: String, _ segments: [String]) -> String? {
        guard segments.first == "repos", segments.count >= 4, method != "GET", method != "HEAD" else { return nil }
        let rest = Array(segments.dropFirst(3))
        if rest.count == 3, rest[0] == "pulls", rest[2] == "merge" { return Owner.merging("\(method) …/pulls/\(rest[1])/merge") }
        if rest == ["merges"] { return Owner.merging("\(method) …/merges") }
        if method == "DELETE", rest.count >= 2, rest[0] == "git", rest[1] == "refs" {
            return Owner.deleting(rest.dropFirst(2).joined(separator: "/").isEmpty ? "git/refs" : "refs/" + rest.dropFirst(2).joined(separator: "/"))
        }
        return nil
    }
}
