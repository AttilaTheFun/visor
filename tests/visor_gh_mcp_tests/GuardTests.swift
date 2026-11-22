// Every guard gh_mcp kept, kept in Visor, a test each (beside the fuller
// tests that came with it: GitTests, MergeTests, PolicyTests, RulesTests):
// pushes only to refs/heads/<branch>, never the default branch or a tag;
// force only with a lease; merges only when every check is green; reviews
// COMMENT only; no state edits on issues; the repositories allowed
// (AttilaTheFun/* unless the settings say otherwise).

import Foundation
import Testing
@testable import VisorGHMCP

/// A checkout of AttilaTheFun/x (its pushes going to a local bare
/// repository) on a branch `feature` with a commit of its own, a tag v1,
/// and a branch `develop`, the repository's default.
private func makeCheckout() throws -> (folder: String, checkout: String, bare: String) {
    let folder = temporaryFolder()
    let bare = folder + "/remote.git", checkout = folder + "/checkout"
    try sh(["git", "init", "-q", "--bare", bare], in: folder)
    try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
    try sh(["git", "init", "-q", "-b", "main"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "one"], in: checkout)
    try sh(["git", "tag", "v1"], in: checkout)
    try sh(["git", "branch", "develop"], in: checkout)
    try sh(["git", "checkout", "-q", "-b", "feature"], in: checkout)
    try sh(["git", "commit", "-q", "--allow-empty", "-m", "two"], in: checkout)
    try sh(["git", "remote", "add", "origin", "https://github.com/AttilaTheFun/x.git"], in: checkout)
    return (folder, checkout, bare)
}

@Test func guardPushesOnlyABranchNeverTheDefaultOrATag() async throws {
    let (_, checkout, bare) = try makeCheckout()
    let transport = FakeTransport(["GET /repos/AttilaTheFun/x": (200, ["default_branch": "develop"])])
    let server = makeServer(transport: transport, remoteURL: { _ in "file://" + bare })
    for branch in ["main", "master", "MAIN", "develop", "refs/heads/develop", "v1", "refs/tags/v1", "refs/heads/../tags/v1",
                   "refs/remotes/origin/feature", "HEAD"] {
        let refused = await call(server, "git_push", ["path": .string(checkout), "branch": .string(branch)])
        #expect(refused.isError && (refused.text.hasPrefix("Refused") || refused.text.hasPrefix("Invalid")), "\(branch): \(refused.text)")
    }
    // The default branch whatever its case on GitHub.
    let cased = makeServer(transport: FakeTransport(["GET /repos/AttilaTheFun/x": (200, ["default_branch": "Develop"])]),
                           remoteURL: { _ in "file://" + bare })
    let otherCase = await call(cased, "git_push", ["path": .string(checkout), "branch": "develop"])
    #expect(otherCase.isError && otherCase.text.contains("default branch"), "\(otherCase.text)")
    #expect(try sh(["git", "for-each-ref", "--format=%(refname)"], in: bare).isEmpty, "nothing reached the remote")
    let pushed = await call(server, "git_push", ["path": .string(checkout), "branch": "refs/heads/feature"])
    #expect(!pushed.isError, "\(pushed.text)")
    #expect(try sh(["git", "for-each-ref", "--format=%(refname)"], in: bare) == "refs/heads/feature", "a branch, under refs/heads, alone")
}

@Test func guardForcesOnlyWithALease() async throws {
    let (_, checkout, bare) = try makeCheckout()
    let transport = FakeTransport(["GET /repos/AttilaTheFun/x": (200, ["default_branch": "main"])])
    let server = makeServer(transport: transport, remoteURL: { _ in "file://" + bare })
    // No remote-tracking branch to lease against: refused, before anything is sent.
    let unleased = await call(server, "git_push", ["path": .string(checkout), "branch": "feature", "force_with_lease": true])
    #expect(unleased.isError && unleased.text.hasPrefix("Refused") && unleased.text.contains("force_with_lease"), "\(unleased.text)")
    #expect(!(await call(server, "git_push", ["path": .string(checkout), "branch": "feature"]).isError))
    // History rewritten: refused without the lease.
    try sh(["git", "commit", "-q", "--amend", "--allow-empty", "-m", "two again"], in: checkout)
    let plain = await call(server, "git_push", ["path": .string(checkout), "branch": "feature"])
    #expect(plain.isError && plain.text.contains("refused"), "\(plain.text)")
    // Someone else moved the remote branch: the lease (what the checkout last saw) fails, nothing replaced.
    let other = try sh(["git", "commit-tree", "-m", "theirs", "HEAD^{tree}"], in: checkout)
    try sh(["git", "push", "-q", "file://" + bare, "\(other):refs/heads/feature", "--force"], in: checkout)
    let stale = await call(server, "git_push", ["path": .string(checkout), "branch": "feature", "force_with_lease": true])
    #expect(stale.isError && stale.text.contains("stale"), "\(stale.text)")
    #expect(try sh(["git", "rev-parse", "refs/heads/feature"], in: bare) == other)
    // With a lease that holds, replaced.
    try sh(["git", "update-ref", "refs/remotes/origin/feature", other], in: checkout)
    let forced = await call(server, "git_push", ["path": .string(checkout), "branch": "feature", "force_with_lease": true])
    #expect(!forced.isError && forced.text.contains("forced"), "\(forced.text)")
    #expect(try sh(["git", "rev-parse", "refs/heads/feature"], in: bare) == sh(["git", "rev-parse", "feature"], in: checkout))
}

@Test func guardMergesOnlyWhenEveryCheckIsGreen() async {
    let failed: JSON = ["total_count": 2, "check_runs": [
        ["name": "linux", "status": "completed", "conclusion": "failure"],
        ["name": "lint", "status": "completed", "conclusion": "success"],
    ]]
    let red = mergeTransport(runs: failed)
    let refused = await call(makeServer(transport: red), "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(refused.isError && refused.text.hasPrefix("Refused") && refused.text.contains("linux concluded failure"), "\(refused.text)")
    #expect(merges(red).isEmpty)
    let green = mergeTransport()
    let merged = await call(makeServer(transport: green), "pr_merge", ["repo": "AttilaTheFun/oss", "number": 50])
    #expect(!merged.isError, "\(merged.text)")
    #expect(merges(green).first?.body?["sha"] == .string(headSHA), "the head it checked, so a push in between is refused")
    // Not around pr_merge: the policy takes a merge only as pr_merge sends it.
    let repo = RepoName("AttilaTheFun/oss")!
    #expect(Policy.refusal(GitHubRequest(method: "PUT", path: "/repos/AttilaTheFun/oss/pulls/50/merge", body: ["merge_method": "squash"]),
                           repo: repo) != nil)
}

@Test func guardReviewsAreCommentsOnly() async {
    let transport = FakeTransport(["POST /repos/AttilaTheFun/oss/pulls/3/reviews": (200, ["id": 1, "state": "COMMENTED"])])
    let server = makeServer(transport: transport)
    #expect(!(await call(server, "pr_review", ["repo": "AttilaTheFun/oss", "number": 3, "body": "fine"]).isError))
    #expect(transport.requests.map { $0.body?["event"] } == ["COMMENT"])
    for event in ["APPROVE", "REQUEST_CHANGES"] {
        let asked = await call(server, "pr_review", ["repo": "AttilaTheFun/oss", "number": 3, "body": "x", "event": .string(event)])
        #expect(asked.isError && asked.text.contains("no argument event"), "\(event): \(asked.text)")
        let sent = GitHubRequest(method: "POST", path: "/repos/AttilaTheFun/oss/pulls/3/reviews", body: ["event": .string(event), "body": "x"])
        #expect(Policy.refusal(sent, repo: RepoName("AttilaTheFun/oss")!)?.contains("COMMENT only") == true)
    }
    #expect(transport.requests.count == 1)
}

@Test func guardNoStateEditsOnIssues() async {
    let transport = FakeTransport(["PATCH /repos/AttilaTheFun/oss/issues/4": (200, ["number": 4, "title": "t"])])
    let server = makeServer(transport: transport)
    for state in ["closed", "open"] {
        let asked = await call(server, "issue_edit", ["repo": "AttilaTheFun/oss", "number": 4, "state": .string(state)])
        #expect(asked.isError && asked.text.contains("no argument state"), "\(asked.text)")
    }
    #expect(transport.requests.isEmpty)
    #expect(!(await call(server, "issue_edit", ["repo": "AttilaTheFun/oss", "number": 4, "title": "t"]).isError))
    #expect(transport.requests.last?.body == ["title": "t"])
    let repo = RepoName("AttilaTheFun/oss")!
    for path in ["/repos/AttilaTheFun/oss/issues/4", "/repos/AttilaTheFun/oss/pulls/4"] {
        #expect(Policy.refusal(GitHubRequest(method: "PATCH", path: path, body: ["state": "closed"]), repo: repo) != nil, "\(path)")
        #expect(Policy.refusal(GitHubRequest(method: "PATCH", path: path, body: ["state_reason": "completed"]), repo: repo) != nil, "\(path)")
    }
    #expect(!Toolbox().tools.contains { $0.name.contains("close") || $0.name.contains("reopen") })
}

@Test func guardOnlyTheRepositoriesAllowed() async throws {
    // The default: AttilaTheFun's alone.
    #expect(MCPServer.Configuration().repositories == ["AttilaTheFun/*"])
    let transport = FakeTransport()
    let standard = makeServer(transport: transport)
    let outside = await call(standard, "pr_list", ["repo": "someone/else"])
    #expect(outside.isError && outside.text.hasPrefix("Refused") && outside.text.contains("AttilaTheFun/*"), "\(outside.text)")
    // Named ones alone, case aside.
    let narrow = makeServer(transport: transport, configuration: MCPServer.Configuration(repositories: ["AttilaTheFun/visor"]))
    #expect(await call(narrow, "pr_list", ["repo": "AttilaTheFun/oss"]).text.hasPrefix("Refused"))
    #expect(transport.requests.isEmpty, "nothing outside reached GitHub")
    _ = await call(narrow, "pr_list", ["repo": "attilathefun/VISOR"])
    #expect(transport.requests.count == 1)
    // A push or fetch to a remote outside them is refused too, and the
    // policy never reads outside the repository named.
    let (_, checkout, _) = try makeCheckout()
    try sh(["git", "remote", "set-url", "origin", "https://github.com/someone/else.git"], in: checkout)
    #expect(await call(standard, "git_push", ["path": .string(checkout), "branch": "feature"]).text.contains("not among"))
    #expect(await call(standard, "git_fetch", ["path": .string(checkout)]).text.hasPrefix("Refused"))
    #expect(Policy.refusal(GitHubRequest(method: "GET", path: "/repos/someone/else/pulls"), repo: RepoName("AttilaTheFun/oss")!) != nil)
}
