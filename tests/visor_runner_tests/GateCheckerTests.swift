// GateChecker (docs/github-gate-rules.md, §2.7-2.8 and §4.2): the reads the
// proxy makes before a merge, an update, a re-run, a cancel, a dispatch, a
// draft's edit, a mutation's nodes or a push go on. gh_mcp's tests ported
// (mergesWhenEverythingIsGreen, mergeRefusesUnlessEveryGuardHolds,
// codeOwnersMatchAsGitHubDoes, rerunRefusedUnlessEveryGuardHolds, …), each a
// table of GitHub's answers.

import Foundation
@testable import VisorRunner
import XCTest

/// GitHub as a table: a path's answer, else 404.
private struct FakeGitHub: GitHubReading {
    var answers: [String: (Int, String)]

    func get(_ path: String) async -> GitHubAnswer {
        guard let (status, body) = answers[path] else { return GitHubAnswer(status: 404, json: nil) }
        return GitHubAnswer(status: status, json: GateJSON.parse(Data(body.utf8)))
    }

    func graphQL(_ query: String, variables: [String: GateJSON]) async -> GitHubAnswer {
        await get(query.contains("nodes(") ? "graphql nodes" : "graphql node")
    }
}

final class GateCheckerTests: XCTestCase {
    private let repo = "AttilaTheFun/shireworks"
    private let head = String(repeating: "a", count: 40)
    private let older = String(repeating: "b", count: 40)

    private func pull(state: String = "open", draft: Bool = false, base: String = "main", headRepo: String = "AttilaTheFun/shireworks",
                      mergeable: String = "clean") -> String {
        """
        {"number":50,"state":"\(state)","merged":false,"draft":\(draft),"mergeable_state":"\(mergeable)",
         "head":{"sha":"\(head)","ref":"feature","repo":{"full_name":"\(headRepo)"}},
         "base":{"ref":"\(base)","repo":{"full_name":"AttilaTheFun/shireworks"}}}
        """
    }

    private func green(_ extra: [String: (Int, String)] = [:], pull given: String? = nil, runs: String? = nil) -> FakeGitHub {
        var answers: [String: (Int, String)] = [
            "/repos/AttilaTheFun/shireworks/pulls/50": (200, given ?? pull()),
            "/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"main","allow_squash_merge":true,"allow_rebase_merge":false}"#),
            "/repos/AttilaTheFun/shireworks/commits/\(head)/check-runs?per_page=100&page=1":
                (200, runs ?? #"{"total_count":1,"check_runs":[{"name":"linux","status":"completed","conclusion":"success"}]}"#),
            "/repos/AttilaTheFun/shireworks/commits/\(head)/status?per_page=100": (403, "{}"),
            "/repos/AttilaTheFun/shireworks/pulls/50/files?per_page=100&page=1": (200, #"[{"filename":"Sources/main.swift"}]"#),
        ]
        answers.merge(extra) { _, new in new }
        return FakeGitHub(answers: answers)
    }

    private func check(_ github: FakeGitHub, _ check: GateCheck) async -> CheckOutcome {
        await GateChecker(rules: .standard, github: github).run(check)
    }

    private func merge(_ github: FakeGitHub, method: String = "squash", sha: String? = nil) async -> CheckOutcome {
        await check(github, .merge(repository: repo, number: 50, sha: sha ?? head, method: method))
    }

    private func refused(_ outcome: CheckOutcome, _ containing: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .refuse(let reason) = outcome else { return XCTFail("not refused: \(outcome)", file: file, line: line) }
        XCTAssertTrue(reason.contains(containing), reason, file: file, line: line)
    }

    // MARK: Merging

    func testAGreenPullRequestMerges() async {
        let outcome = await merge(green())
        XCTAssertEqual(outcome, .pass(nil))
        // A readable status counts; a pending one holds the merge.
        let success = await merge(green(["/repos/AttilaTheFun/shireworks/commits/\(head)/status?per_page=100": (200, #"{"statuses":[{"context":"ci/x","state":"success"}]}"#)]))
        XCTAssertEqual(success, .pass(nil))
        let pending = await merge(green(["/repos/AttilaTheFun/shireworks/commits/\(head)/status?per_page=100": (200, #"{"statuses":[{"context":"ci/x","state":"pending"}]}"#)]))
        refused(pending, "ci/x is pending")
    }

    func testAMergeIsRefusedUnlessEveryGuardHolds() async {
        refused(await merge(green(pull: pull(draft: true, mergeable: "draft"))), "is a draft")
        refused(await merge(green(pull: pull(state: "closed"))), "is closed")
        refused(await merge(green(pull: pull(base: "release"))), "not AttilaTheFun/shireworks's default branch main")
        refused(await merge(green(pull: pull(headRepo: "someone/shireworks"))), "in someone/shireworks")
        refused(await merge(green(pull: pull(mergeable: "behind"))), "update its branch")
        for state in ["blocked", "dirty", "unstable"] { refused(await merge(green(pull: pull(mergeable: state))), "mergeable_state is \(state)") }
        refused(await merge(green(pull: pull(mergeable: "unknown"))), "still working out")
        refused(await merge(green(runs: #"{"total_count":1,"check_runs":[{"name":"linux","status":"in_progress"}]}"#)), "linux is in_progress")
        refused(await merge(green(runs: #"{"total_count":1,"check_runs":[{"name":"linux","status":"completed","conclusion":"failure"}]}"#)),
                "linux concluded failure")
        refused(await merge(green(runs: #"{"total_count":1,"check_runs":[{"name":"linux","status":"queued"}]}"#)), "linux is queued")
        refused(await merge(green(runs: #"{"total_count":0,"check_runs":[]}"#)), "no check runs")
        refused(await merge(green(), method: "rebase"), "doesn't allow rebase")
        // The SHA it merges must be the head it read ([M13]).
        refused(await merge(green(), sha: older), "check it again")
    }

    func testAnUpdatesPullRequestIsFromItsOwnRepository() async {
        let outcome = await check(green(), .updateBranch(repository: repo, number: 50))
        XCTAssertEqual(outcome, .pass(nil))
        refused(await check(green(pull: pull(headRepo: "someone/shireworks")), .updateBranch(repository: repo, number: 50)), "in someone/shireworks")
    }

    func testGhPrMergeIsPinnedToTheHeadItChecked() async {
        let github = green(["graphql node": (200, #"{"data":{"node":{"__typename":"PullRequest","number":50,"repository":{"nameWithOwner":"AttilaTheFun/shireworks"}}}}"#)])
        let outcome = await check(github, .graphQLMerge(pullRequestID: "PR_1", method: "squash", variable: "input", expectedHeadOid: nil))
        XCTAssertEqual(outcome, .pass(.variableField(variable: "input", field: "expectedHeadOid", value: .string(head))))
        refused(await check(github, .graphQLMerge(pullRequestID: "PR_1", method: "squash", variable: nil, expectedHeadOid: nil)), "variable")
        refused(await check(github, .graphQLMerge(pullRequestID: "PR_1", method: "squash", variable: "input", expectedHeadOid: older)), "check it again")
    }

    // MARK: CODEOWNERS

    private let guardrails = """
        # Pull requests that touch these need the owner's review.
        /.github/ @AttilaTheFun
        AGENTS.md @AttilaTheFun
        /LICENSE @AttilaTheFun
        /tools/signing/ @AttilaTheFun
        /tools/ci/publish_from_ci.sh @AttilaTheFun
        docs/**/secret.md @AttilaTheFun
        /tools/signing/README.md
        """

    func testCodeOwnersMatchAsGitHubDoes() {
        let owners = CodeOwners(guardrails)
        for owned in [".github/workflows/ci.yml", ".github/CODEOWNERS", "AGENTS.md", "swift_ffi/AGENTS.md", "LICENSE",
                      "tools/signing/sign.sh", "tools/ci/publish_from_ci.sh", "docs/a/b/secret.md", "docs/secret.md"] {
            XCTAssertEqual(owners.owners(of: owned), ["@AttilaTheFun"], owned)
        }
        for free in ["Sources/main.swift", "README.md", "swift_ffi/LICENSE", "tools/ci/container_build.sh", "github/x",
                     "tools/signing/README.md", "AGENTS.md.bak", "x/.github/y"] {
            XCTAssertEqual(owners.owners(of: free), [], free)
        }
        XCTAssertEqual(CodeOwners("* @someone").owners(of: "a/b/c"), ["@someone"])
    }

    private func owned(reviews: String) -> FakeGitHub {
        green([
            "/repos/AttilaTheFun/shireworks/contents/.github/CODEOWNERS?ref=main": (200, "{\"content\":\"\(Data(guardrails.utf8).base64EncodedString())\"}"),
            "/repos/AttilaTheFun/shireworks/pulls/50/files?per_page=100&page=1": (200, #"[{"filename":".github/workflows/ci.yml"},{"filename":"Sources/a.swift"}]"#),
            "/repos/AttilaTheFun/shireworks/pulls/50/reviews?per_page=100&page=1": (200, reviews),
        ])
    }

    func testProtectedFilesNeedTheOwnersApprovalOfTheHead() async {
        refused(await merge(owned(reviews: "[]")), "@AttilaTheFun hasn't approved its head")
        refused(await merge(owned(reviews: "[{\"user\":{\"login\":\"AttilaTheFun\"},\"state\":\"APPROVED\",\"commit_id\":\"\(older)\"}]")),
                ".github/workflows/ci.yml")
        refused(await merge(owned(reviews: "[{\"user\":{\"login\":\"someone\"},\"state\":\"APPROVED\",\"commit_id\":\"\(head)\"}]")), "hasn't approved")
        refused(await merge(owned(reviews: """
            [{"user":{"login":"AttilaTheFun"},"state":"APPROVED","commit_id":"\(head)"},
             {"user":{"login":"AttilaTheFun"},"state":"CHANGES_REQUESTED","commit_id":"\(head)"}]
            """)), "hasn't approved")
        let approved = await merge(owned(reviews: """
            [{"user":{"login":"attilathefun"},"state":"APPROVED","commit_id":"\(head)"},
             {"user":{"login":"someone"},"state":"COMMENTED","commit_id":"\(head)"}]
            """))
        XCTAssertEqual(approved, .pass(nil))
    }

    // MARK: Actions

    private func runs(_ run: String, extra: [String: (Int, String)] = [:]) -> FakeGitHub {
        var answers: [String: (Int, String)] = [
            "/repos/AttilaTheFun/shireworks/actions/runs/77": (200, run),
            "/repos/AttilaTheFun/shireworks/pulls?head=AttilaTheFun:feature&state=open&per_page=10": (200, "[{\"head\":{\"sha\":\"\(head)\"}}]"),
            "/repos/AttilaTheFun/shireworks/git/ref/heads/feature": (200, "{\"object\":{\"sha\":\"\(head)\"}}"),
        ]
        answers.merge(extra) { _, new in new }
        return FakeGitHub(answers: answers)
    }

    private func run(event: String = "pull_request", status: String = "completed", conclusion: String = "failure",
                     headRepo: String = "AttilaTheFun/shireworks", sha: String? = nil) -> String {
        """
        {"id":77,"name":"CI","event":"\(event)","status":"\(status)","conclusion":"\(conclusion)","head_branch":"feature",
         "head_sha":"\(sha ?? head)","head_repository":{"full_name":"\(headRepo)"}}
        """
    }

    func testARunIsRunAgainAtItsBranchsHead() async {
        let failed = await check(runs(run()), .rerun(repository: repo, run: 77, failedOnly: true))
        XCTAssertEqual(failed, .pass(nil))
        let push = await check(runs(run(event: "push", conclusion: "success")), .rerun(repository: repo, run: 77, failedOnly: false))
        XCTAssertEqual(push, .pass(nil))
        let dispatched = await check(runs(run(event: "workflow_dispatch")), .rerun(repository: repo, run: 77, failedOnly: true))
        XCTAssertEqual(dispatched, .pass(nil))
    }

    func testAReRunIsRefusedUnlessEveryGuardHolds() async {
        let rerun = GateCheck.rerun(repository: repo, run: 77, failedOnly: true)
        refused(await check(runs(run(sha: older)), rerun), "only the head's runs")
        refused(await check(runs(run(event: "push", sha: older)), rerun), "only the head's runs")
        refused(await check(runs(run(status: "in_progress")), rerun), "is in_progress, not completed")
        refused(await check(runs(run(status: "queued")), rerun), "is queued, not completed")
        refused(await check(runs(run(event: "release")), rerun), "is a release run")
        refused(await check(runs(run(event: "schedule")), rerun), "is a schedule run")
        refused(await check(runs(run(headRepo: "someone/shireworks")), rerun), "in someone/shireworks")
        refused(await check(runs(run(), extra: ["/repos/AttilaTheFun/shireworks/pulls?head=AttilaTheFun:feature&state=open&per_page=10": (200, "[]")]), rerun),
                "no pull request from feature is open")
        refused(await check(runs(run(event: "push"), extra: ["/repos/AttilaTheFun/shireworks/git/ref/heads/feature": (404, "{}")]), rerun),
                "no longer a branch")
        refused(await check(runs(run(conclusion: "success")), rerun), "no job failed")
    }

    func testACancelIsOfARunStillGoingNeverARelease() async {
        let going = await check(runs(run(status: "in_progress")), .cancel(repository: repo, run: 77))
        XCTAssertEqual(going, .pass(nil))
        refused(await check(runs(run(event: "release", status: "in_progress")), .cancel(repository: repo, run: 77)), "its publishing must finish")
        refused(await check(runs(run()), .cancel(repository: repo, run: 77)), "already completed")
    }

    func testADispatchIsOfAnActiveWorkflowOnABranch() async {
        let github = FakeGitHub(answers: [
            "/repos/AttilaTheFun/shireworks/actions/workflows/12": (200, #"{"id":12,"name":"CI","state":"active"}"#),
            "/repos/AttilaTheFun/shireworks/git/ref/heads/feature": (200, "{\"object\":{\"sha\":\"\(head)\"}}"),
            "/repos/AttilaTheFun/shireworks/actions/workflows/13": (200, #"{"id":13,"name":"Old","state":"disabled_manually"}"#),
        ])
        let dispatched = await check(github, .dispatch(repository: repo, workflow: 12, branch: "feature"))
        XCTAssertEqual(dispatched, .pass(nil))
        refused(await check(github, .dispatch(repository: repo, workflow: 13, branch: "feature")), "disabled_manually")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "gone")), "gone is not a branch")
    }

    // MARK: Drafts, nodes and pushes

    func testOnlyADraftIsEditedAndItsTagKept() async {
        let github = FakeGitHub(answers: [
            "/repos/AttilaTheFun/shireworks/releases/8": (200, #"{"id":8,"tag_name":"v1.0","draft":false}"#),
            "/repos/AttilaTheFun/shireworks/releases/9": (200, #"{"id":9,"tag_name":"v1.1","draft":true}"#),
        ])
        refused(await check(github, .releaseEdit(repository: repo, release: 8)), "is published")
        let draft = await check(github, .releaseEdit(repository: repo, release: 9))
        XCTAssertEqual(draft, .pass(.bodyFieldIfAbsent("tag_name", .string("v1.1"))))
    }

    func testAMutationsNodesAreInAllowedRepositories() async {
        let nodes: [GateCheck.GraphQLNode] = [.init(id: "PR_1", kinds: ["PullRequest"])]
        let allowed = FakeGitHub(answers: ["graphql nodes": (200, #"{"data":{"nodes":[{"__typename":"PullRequest","repository":{"nameWithOwner":"AttilaTheFun/visor"}}]}}"#)])
        let resolved = await check(allowed, .graphQLNodes(nodes))
        XCTAssertEqual(resolved, .pass(nil))
        let other = FakeGitHub(answers: ["graphql nodes": (200, #"{"data":{"nodes":[{"__typename":"PullRequest","repository":{"nameWithOwner":"someone/else"}}]}}"#)])
        refused(await check(other, .graphQLNodes(nodes)), "not among the repositories")
        let issue = FakeGitHub(answers: ["graphql nodes": (200, #"{"data":{"nodes":[{"__typename":"Issue","repository":{"nameWithOwner":"AttilaTheFun/visor"}}]}}"#)])
        refused(await check(issue, .graphQLNodes(nodes)), "not a PullRequest")
        refused(await check(FakeGitHub(answers: ["graphql nodes": (200, #"{"data":{"nodes":[null]}}"#)]), .graphQLNodes(nodes)), "no node")
    }

    func testAPushNeverReachesTheDefaultBranch() async {
        let github = FakeGitHub(answers: ["/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"develop"}"#)])
        let feature = await check(github, .push(repository: repo, branches: ["feature"]))
        XCTAssertEqual(feature, .pass(nil))
        refused(await check(github, .push(repository: repo, branches: ["feature", "Develop"])), "default branch")
    }
}
