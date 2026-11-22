// pr_merge and pr_update_branch, and CODEOWNERS, as they came.

import Foundation
import Testing
@testable import VisorGHMCP

// MARK: Merging

let headSHA = String(repeating: "c", count: 40)

func mergeablePull(_ changes: [String: JSON] = [:]) -> JSON {
    var pull: [String: JSON] = [
        "number": 50, "state": "open", "draft": false, "merged": false, "mergeable": true, "mergeable_state": "clean",
        "head": ["ref": "feature", "sha": .string(headSHA), "repo": ["full_name": "AttilaTheFun/oss"]],
        "base": ["ref": "main", "repo": ["full_name": "AttilaTheFun/oss"]],
    ]
    for (key, value) in changes { pull[key] = value }
    return .object(pull)
}

let greenRuns: JSON = ["total_count": 2, "check_runs": [
    ["name": "linux", "status": "completed", "conclusion": "success"],
    ["name": "lint", "status": "completed", "conclusion": "skipped"],
]]

/// A fake GitHub where pull request 50 of AttilaTheFun/oss is ready to
/// merge, with `changes` to its answers.
func mergeTransport(pull: JSON = mergeablePull(), runs: JSON = greenRuns,
                    _ changes: [String: (Int, JSON)] = [:]) -> FakeTransport {
    var answers: [String: (Int, JSON)] = [
        "GET /repos/AttilaTheFun/oss/pulls/50": (200, pull),
        "GET /repos/AttilaTheFun/oss": (200, ["default_branch": "main", "allow_squash_merge": true, "allow_rebase_merge": false]),
        "GET /repos/AttilaTheFun/oss/commits/\(headSHA)/check-runs": (200, runs),
        "GET /repos/AttilaTheFun/oss/commits/\(headSHA)/status": (403, ["message": "Resource not accessible by integration"]),
        "PUT /repos/AttilaTheFun/oss/pulls/50/merge": (200, ["sha": "d00d", "merged": true, "message": "Pull Request successfully merged"]),
        "PUT /repos/AttilaTheFun/oss/pulls/50/update-branch": (202, ["message": "Updating pull request branch.", "url": "https://github.com/AttilaTheFun/oss/pull/50"]),
    ]
    for (key, value) in changes { answers[key] = value }
    return FakeTransport(answers)
}

func merges(_ transport: FakeTransport) -> [GitHubRequest] {
    transport.requests.filter { $0.method == "PUT" && $0.path.hasSuffix("/merge") }
}

@Test func mergesWhenEverythingIsGreen() async {
    let transport = mergeTransport()
    let server = makeServer(transport: transport)
    let answer = await call(server, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50, "title": "One (#50)"])
    #expect(!answer.isError, "\(answer.text)")
    #expect(answer.text.contains("d00d"))
    #expect(merges(transport).count == 1)
    #expect(merges(transport).first?.body == ["merge_method": "squash", "sha": .string(headSHA), "commit_title": "One (#50)"])
}

@Test func mergeCountsReadableStatuses() async {
    let passing = mergeTransport(["GET /repos/AttilaTheFun/oss/commits/\(headSHA)/status": (200, ["statuses": [["context": "ci/x", "state": "success"]]])])
    let server = makeServer(transport: passing)
    #expect(!(await call(server, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50]).isError))
    let pending = mergeTransport(["GET /repos/AttilaTheFun/oss/commits/\(headSHA)/status": (200, ["statuses": [["context": "ci/x", "state": "pending"]]])])
    let other = makeServer(transport: pending)
    let answer = await call(other, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(answer.isError && answer.text.contains("ci/x is pending"), "\(answer.text)")
    #expect(merges(pending).isEmpty)
}

@Test func mergeRefusesUnlessEveryGuardHolds() async {
    let pending: JSON = ["total_count": 2, "check_runs": [
        ["name": "linux", "status": "in_progress", "conclusion": .null],
        ["name": "lint", "status": "completed", "conclusion": "success"],
    ]]
    let failed: JSON = ["total_count": 2, "check_runs": [
        ["name": "linux", "status": "completed", "conclusion": "failure"],
        ["name": "lint", "status": "completed", "conclusion": "success"],
    ]]
    let rerunQueued: JSON = ["total_count": 2, "check_runs": [
        ["name": "linux", "status": "queued", "conclusion": .null],
        ["name": "lint", "status": "completed", "conclusion": "success"],
    ]]
    let cases: [(String, FakeTransport, [String: JSON], String)] = [
        ("draft", mergeTransport(pull: mergeablePull(["draft": true, "mergeable_state": "draft"])), [:], "is a draft"),
        ("closed", mergeTransport(pull: mergeablePull(["state": "closed"])), [:], "is closed"),
        ("non-default base", mergeTransport(pull: mergeablePull(["base": ["ref": "release", "repo": ["full_name": "AttilaTheFun/oss"]]])), [:],
         "not AttilaTheFun/oss's default branch main"),
        ("fork", mergeTransport(pull: mergeablePull(["head": ["ref": "feature", "sha": .string(headSHA), "repo": ["full_name": "someone/oss"]]])), [:],
         "in someone/oss"),
        ("behind", mergeTransport(pull: mergeablePull(["mergeable_state": "behind"])), [:], "pr_update_branch"),
        ("blocked", mergeTransport(pull: mergeablePull(["mergeable_state": "blocked"])), [:], "mergeable_state is blocked"),
        ("dirty", mergeTransport(pull: mergeablePull(["mergeable_state": "dirty"])), [:], "mergeable_state is dirty"),
        ("unstable", mergeTransport(pull: mergeablePull(["mergeable_state": "unstable"])), [:], "mergeable_state is unstable"),
        ("pending check", mergeTransport(runs: pending), [:], "linux is in_progress"),
        ("failed check", mergeTransport(runs: failed), [:], "linux concluded failure"),
        // A run_rerun in progress: the head's check run is back to queued.
        ("re-run queued", mergeTransport(runs: rerunQueued), [:], "linux is queued"),
        ("no check runs", mergeTransport(runs: ["total_count": 0, "check_runs": []]), [:], "no check runs"),
        ("rebase not allowed", mergeTransport(), ["method": "rebase"], "doesn't allow rebase"),
    ]
    for (name, transport, extra, reason) in cases {
        let server = makeServer(transport: transport)
        var arguments: [String: JSON] = ["repo": "AttilaTheFun/oss", "number": 50]
        for (key, value) in extra { arguments[key] = value }
        let answer = await call(server, "pr_merge", .object(arguments))
        #expect(answer.isError && answer.text.hasPrefix("Refused") && answer.text.contains(reason), "\(name): \(answer.text)")
        #expect(merges(transport).isEmpty, "\(name) sent a merge")
    }
}

@Test func mergeRefusedWhenTheHeadChanged() async {
    for status in [409, 405] {
        let transport = mergeTransport(["PUT /repos/AttilaTheFun/oss/pulls/50/merge": (status, ["message": "Head branch was modified. Review and try the merge again."])])
        let server = makeServer(transport: transport)
        let answer = await call(server, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
        #expect(answer.isError && answer.text.hasPrefix("Refused") && answer.text.contains("modified"), "\(status): \(answer.text)")
        #expect(merges(transport).first?.body?["sha"] == .string(headSHA))
    }
}

@Test func updateBranchSendsTheExpectedHead() async {
    let transport = mergeTransport(pull: mergeablePull(["mergeable_state": "behind"]))
    let server = makeServer(transport: transport)
    let answer = await call(server, "pr_update_branch", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(!answer.isError && answer.text.contains("updating"), "\(answer.text)")
    let update = transport.requests.first { $0.method == "PUT" }
    #expect(update?.path == "/repos/AttilaTheFun/oss/pulls/50/update-branch")
    #expect(update?.body == ["expected_head_sha": .string(headSHA)])

    let fork = mergeTransport(pull: mergeablePull(["head": ["ref": "feature", "sha": .string(headSHA), "repo": ["full_name": "someone/oss"]]]))
    let forkServer = makeServer(transport: fork)
    let refused = await call(forkServer, "pr_update_branch", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(refused.isError && refused.text.hasPrefix("Refused"), "\(refused.text)")
    #expect(!fork.requests.contains { $0.method == "PUT" })
}

// MARK: CODEOWNERS

let guardrails = """
    # Protected: these need the owner's review.
    /.github/ @AttilaTheFun
    AGENTS.md @AttilaTheFun
    /LICENSE @AttilaTheFun
    /tools/signing/ @AttilaTheFun
    /tools/ci/publish_*.sh @AttilaTheFun
    docs/**/secret.md @AttilaTheFun
    /tools/signing/README.md
    """

@Test func codeOwnersMatchAsGitHubDoes() {
    let owners = CodeOwners(guardrails)
    let owned = [".github/workflows/ci.yml", ".github/CODEOWNERS", "AGENTS.md", "swift_ffi/AGENTS.md", "LICENSE",
                 "tools/signing/sign.sh", "tools/ci/publish_from_ci.sh", "docs/a/b/secret.md", "docs/secret.md"]
    for path in owned { #expect(owners.owners(of: path) == ["@AttilaTheFun"], "\(path)") }
    let free = ["Sources/main.swift", "README.md", "swift_ffi/LICENSE", "tools/ci/container_build.sh", "github/x",
                "tools/signing/README.md", "AGENTS.md.bak", "x/.github/y"]
    for path in free { #expect(owners.owners(of: path).isEmpty, "\(path)") }
    #expect(CodeOwners("* @someone").owners(of: "a/b/c") == ["@someone"])
}

func codeOwnersAnswer(_ text: String) -> (Int, JSON) {
    (200, ["encoding": "base64", "content": .string(Data(text.utf8).base64EncodedString())])
}

func guardedTransport(files: [String], reviews: JSON = []) -> FakeTransport {
    mergeTransport([
        "GET /repos/AttilaTheFun/oss/contents/.github/CODEOWNERS": codeOwnersAnswer(guardrails),
        "GET /repos/AttilaTheFun/oss/pulls/50/files": (200, .array(files.map { ["filename": .string($0)] })),
        "GET /repos/AttilaTheFun/oss/pulls/50/reviews": (200, reviews),
    ])
}

@Test func mergeRefusesProtectedFilesWithoutTheOwnersApproval() async {
    let older = String(repeating: "b", count: 40)
    let cases: [(String, JSON)] = [
        ("no review", []),
        ("approved an older head", [["user": ["login": "AttilaTheFun"], "state": "APPROVED", "commit_id": .string(older)]]),
        ("someone else approved", [["user": ["login": "someone"], "state": "APPROVED", "commit_id": .string(headSHA)]]),
        ("then asked for changes", [["user": ["login": "AttilaTheFun"], "state": "APPROVED", "commit_id": .string(headSHA)],
                                    ["user": ["login": "AttilaTheFun"], "state": "CHANGES_REQUESTED", "commit_id": .string(headSHA)]]),
    ]
    for (name, reviews) in cases {
        let transport = guardedTransport(files: ["Sources/a.swift", ".github/workflows/ci.yml"], reviews: reviews)
        let server = makeServer(transport: transport)
        let answer = await call(server, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
        #expect(answer.isError && answer.text.hasPrefix("Refused") && answer.text.contains(".github/workflows/ci.yml")
                && answer.text.contains("@AttilaTheFun"), "\(name): \(answer.text)")
        #expect(merges(transport).isEmpty, "\(name) sent a merge")
    }
}

@Test func mergeAllowsUnprotectedFilesAndApprovedProtectedOnes() async {
    let unprotected = guardedTransport(files: ["Sources/a.swift", "README.md"])
    let server = makeServer(transport: unprotected)
    let free = await call(server, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(!free.isError, "\(free.text)")
    #expect(merges(unprotected).count == 1)

    let approved = guardedTransport(files: ["AGENTS.md"], reviews: [
        ["user": ["login": "someone"], "state": "COMMENTED", "commit_id": .string(headSHA)],
        ["user": ["login": "attilathefun"], "state": "APPROVED", "commit_id": .string(headSHA)],
    ])
    let other = makeServer(transport: approved)
    let answer = await call(other, "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(!answer.isError, "\(answer.text)")
    #expect(merges(approved).count == 1)
}
