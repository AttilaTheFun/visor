// The never-list (Policy), the new writes, git_fetch, pr_ready_for_review and
// checks, as they came.

import Foundation
import Testing
@testable import VisorGHMCP

// MARK: Round two: the never-list, git_fetch, the new tools

@Test func policyRefusesWhatGoesThroughLogan() {
    let repo = RepoName("AttilaTheFun/oss")!
    func refused(_ method: String, _ path: String, _ body: JSON? = nil, query: [String: String] = [:]) -> Bool {
        Policy.refusal(GitHubRequest(method: method, path: path, query: query, body: body), repo: repo) != nil
    }
    // Never.
    let sha = String(repeating: "a", count: 40)
    // A merge only as pr_merge sends it: the head named, a method, nothing
    // else (no admin bypass), at that path alone.
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge"))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash"]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash", "sha": "main"]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "fast-forward", "sha": .string(sha)]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash", "sha": .string(sha), "admin": true]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash", "sha": .string(sha), "delete_branch": true]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash", "sha": .string(sha)]))
    #expect(refused("PUT", "/repos/someone/else/pulls/3/merge", ["merge_method": "squash", "sha": .string(sha)]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/merges", ["base": "main", "head": "feature"]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/update-branch"))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/update-branch", ["expected_head_sha": .string(sha), "update_method": "rebase"]))
    #expect(refused("PATCH", "/repos/AttilaTheFun/oss/pulls/3", ["state": "closed"]))
    #expect(refused("PATCH", "/repos/AttilaTheFun/oss/issues/3", ["state": "closed"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/pulls/3/reviews", ["event": "APPROVE", "body": "x"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/pulls/3/reviews", ["event": "REQUEST_CHANGES", "body": "x"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/releases", ["tag_name": "v1", "draft": false]))
    #expect(refused("PATCH", "/repos/AttilaTheFun/oss/releases/9", ["draft": false]))
    #expect(refused("PATCH", "/repos/AttilaTheFun/oss/releases/9", ["make_latest": "true"]))
    #expect(refused("DELETE", "/repos/AttilaTheFun/oss/git/refs/heads/x"))
    #expect(refused("DELETE", "/repos/AttilaTheFun/oss/issues/comments/5"))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/git/refs", ["ref": "refs/tags/v1", "sha": "abc"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/rerun-failed-jobs", ["enable_debug_logging": true]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/rerun", ["enable_debug_logging": true]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/force-cancel"))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/approve"))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/jobs/1/rerun"))
    #expect(refused("DELETE", "/repos/AttilaTheFun/oss/actions/runs/1"))
    #expect(refused("DELETE", "/repos/AttilaTheFun/oss/actions/runs/1/logs"))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/actions/permissions", ["enabled": false]))
    #expect(refused("POST", "/repos/someone/else/actions/runs/1/cancel"))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/runs/main/rerun"))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/workflows/ci.yml/dispatches", ["ref": "main"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/workflows/12/dispatches", ["ref": "refs/tags/v1"]))
    #expect(refused("POST", "/repos/AttilaTheFun/oss/actions/workflows/12/dispatches", ["ref": "main", "return_run_details": true]))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/branches/main/protection"))
    #expect(refused("PUT", "/repos/AttilaTheFun/oss/actions/secrets/X"))
    #expect(refused("PATCH", "/repos/AttilaTheFun/oss", ["private": false]))
    #expect(refused("POST", "/graphql", ["query": "mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"]))
    #expect(refused("GET", "/repos/someone/else/pulls"))
    #expect(refused("POST", "/repos/someone/else/issues", ["title": "x"]))
    // Allowed.
    #expect(!refused("GET", "/repos/AttilaTheFun/oss/pulls/3/comments"))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/pulls/3/reviews", ["event": "COMMENT", "body": "x"]))
    #expect(!refused("PATCH", "/repos/AttilaTheFun/oss/issues/3", ["title": "t", "labels": ["bug"]]))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/pulls/3/comments/77/replies", ["body": "x"]))
    #expect(!refused("POST", "/graphql", ["query": .string(Policy.readyMutations[0]), "variables": ["id": "x"]]))
    #expect(!refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/merge", ["merge_method": "squash", "sha": .string(sha),
                                                                       "commit_title": "t", "commit_message": "m"]))
    #expect(!refused("PUT", "/repos/AttilaTheFun/oss/pulls/3/update-branch", ["expected_head_sha": .string(sha)]))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/rerun-failed-jobs"))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/rerun"))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/actions/runs/1/cancel"))
    #expect(!refused("POST", "/repos/AttilaTheFun/oss/actions/workflows/12/dispatches", ["ref": "main", "inputs": ["kind": "quick"]]))
    #expect(!Policy.never.contains("merge a pull request"))
}

@Test func newWritesAreNonDestructive() async {
    let transport = FakeTransport([
        "POST /repos/AttilaTheFun/oss/pulls/3/reviews": (200, ["id": 1, "state": "COMMENTED"]),
        "PATCH /repos/AttilaTheFun/oss/issues/4": (200, ["number": 4, "title": "t"]),
    ])
    let server = makeServer(transport: transport)
    #expect(!(await call(server, "pr_review", ["repo": "AttilaTheFun/oss", "number": 3, "body": "looks fine"]).isError))
    #expect(transport.requests.last?.body?["event"] == "COMMENT")
    #expect(!(await call(server, "issue_edit", ["repo": "AttilaTheFun/oss", "number": 4, "labels": "bug, ui"]).isError))
    #expect(transport.requests.last?.body == ["labels": ["bug", "ui"]])
    #expect(await call(server, "issue_edit", ["repo": "AttilaTheFun/oss", "number": 4, "state": "closed"]).text.contains("no argument state"))
}

@Test func fetchBringsBranchesIntoTrackingRefs() async throws {
    let folder = temporaryFolder()
    let bare = folder + "/remote.git", checkout = folder + "/checkout", other = folder + "/other"
    try sh(["git", "init", "-q", "--bare", "-b", "main", bare], in: folder)
    try sh(["git", "clone", "-q", bare, other], in: folder)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "one"], in: other)
    try sh(["git", "push", "-q", "origin", "HEAD:main"], in: other)
    try sh(["git", "clone", "-q", bare, checkout], in: folder)
    try sh(["git", "remote", "set-url", "origin", "https://github.com/AttilaTheFun/x.git"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "two"], in: other)
    try sh(["git", "push", "-q", "origin", "HEAD:main", "HEAD:refs/heads/feature"], in: other)
    let hook = checkout + "/.git/hooks/reference-transaction"
    try "#!/bin/sh\ntouch \(folder)/hook-ran\n".write(toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    let configBefore = try String(contentsOfFile: checkout + "/.git/config", encoding: .utf8)
    let server = makeServer(remoteURL: { _ in "file://" + bare })

    let some = await call(server, "git_fetch", ["path": .string(checkout), "refs": "feature"])
    #expect(!some.isError, "\(some.text)")
    let head = try sh(["git", "rev-parse", "main"], in: other)
    #expect(try sh(["git", "rev-parse", "refs/remotes/origin/feature"], in: checkout) == head)
    #expect(try sh(["git", "rev-parse", "refs/remotes/origin/main"], in: checkout) != head)
    let all = await call(server, "git_fetch", ["path": .string(checkout)])
    #expect(!all.isError && all.text.contains("origin/main"), "\(all.text)")
    #expect(try sh(["git", "rev-parse", "refs/remotes/origin/main"], in: checkout) == head)
    #expect(try String(contentsOfFile: checkout + "/.git/config", encoding: .utf8) == configBefore)
    #expect(!FileManager.default.fileExists(atPath: folder + "/hook-ran"))
    #expect(await call(server, "git_fetch", ["path": .string(checkout), "refs": "refs/tags/v1"]).text.hasPrefix("Invalid"))
    try sh(["git", "remote", "set-url", "origin", "https://github.com/someone/else.git"], in: checkout)
    #expect(await call(server, "git_fetch", ["path": .string(checkout)]).text.hasPrefix("Refused"))
}

// MARK: Ready for review

let draftPull: JSON = ["number": 48, "node_id": "PR_x", "draft": true]
let readyPull: JSON = ["number": 48, "node_id": "PR_x", "draft": false]

@Test func readyForReviewMakesADraftReady() async {
    let transport = FakeTransport([
        "GET /repos/AttilaTheFun/reviews/pulls/48": (200, draftPull),
        "POST /graphql": (200, ["data": ["markPullRequestReadyForReview": ["pullRequest": ["number": 48, "isDraft": false]]]]),
    ])
    let server = makeServer(transport: transport)
    let answer = await call(server, "pr_ready_for_review", ["repo": "AttilaTheFun/reviews", "number": 48])
    #expect(!answer.isError)
    #expect(transport.requests.contains { $0.method == "POST" && $0.path == "/graphql" })
}

@Test func readyForReviewLeavesAReadyPullRequestAlone() async {
    let transport = FakeTransport(["GET /repos/AttilaTheFun/reviews/pulls/48": (200, readyPull)])
    let server = makeServer(transport: transport)
    let answer = await call(server, "pr_ready_for_review", ["repo": "AttilaTheFun/reviews", "number": 48])
    #expect(!answer.isError)
    #expect(!transport.requests.contains { $0.path == "/graphql" })
}

@Test func readyForReviewFailsWhenNothingChanged() async {
    let transport = FakeTransport([
        "GET /repos/AttilaTheFun/reviews/pulls/48": (200, draftPull),
        "POST /graphql": (200, ["data": ["markPullRequestReadyForReview": ["pullRequest": ["number": 48, "isDraft": true]]]]),
    ])
    let server = makeServer(transport: transport)
    let answer = await call(server, "pr_ready_for_review", ["repo": "AttilaTheFun/reviews", "number": 48])
    #expect(answer.isError && answer.text.contains("still a draft"))
}

// MARK: Checks

@Test func checksAnswerRunsWhereStatusesAreForbidden() async {
    let transport = FakeTransport([
        "GET /repos/AttilaTheFun/reviews/commits/main/check-runs": (200, ["total_count": 1, "check_runs": [["name": "linux", "status": "completed", "conclusion": "success", "head_sha": "abc"]]]),
        "GET /repos/AttilaTheFun/reviews/commits/main/status": (403, ["message": "Resource not accessible by integration"]),
    ])
    let server = makeServer(transport: transport)
    let answer = await call(server, "checks", ["repo": "AttilaTheFun/reviews", "ref": "main"])
    #expect(!answer.isError)
    #expect(answer.text.contains("1 passed") && answer.text.contains("statuses_note"))
}
