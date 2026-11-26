// GateChecker (docs/github-gate-rules.md, §2.7-2.8 and §4.2): the reads the
// proxy makes before a merge, an update, a re-run, a cancel, a dispatch, a
// draft's edit, a mutation's nodes or a push go on. gh_mcp's tests ported
// (mergesWhenEverythingIsGreen, mergeRefusesUnlessEveryGuardHolds,
// codeOwnersMatchAsGitHubDoes, rerunRefusedUnlessEveryGuardHolds, …), each a
// table of GitHub's answers. Moved from MultiPass (Logan, 2026-11-14); the
// merge's checks are kept and tested, though the gate now refuses every
// merge before any check (merging is Logan's alone).

import Foundation
@testable import VisorAgentProxy
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

    private func check(_ github: FakeGitHub, _ check: GateCheck, rules: GateRules = .standard) async -> CheckOutcome {
        await GateChecker(rules: rules, github: github).run(check)
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
            "/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"main"}"#),
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

    /// A dispatch: of a workflow gate.json lists (by its file), active, on a
    /// branch that's there and isn't the default (NCH's review of #417).
    func testADispatchIsOfAListedActiveWorkflowOnABranchNotTheDefault() async {
        let github = FakeGitHub(answers: [
            "/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"develop"}"#),
            "/repos/AttilaTheFun/shireworks/actions/workflows/12": (200, #"{"id":12,"name":"CI","path":".github/workflows/ci.yml","state":"active"}"#),
            "/repos/AttilaTheFun/shireworks/git/ref/heads/feature": (200, "{\"object\":{\"sha\":\"\(head)\"}}"),
            "/repos/AttilaTheFun/shireworks/git/ref/heads/develop": (200, "{\"object\":{\"sha\":\"\(head)\"}}"),
            "/repos/AttilaTheFun/shireworks/actions/workflows/13": (200, #"{"id":13,"name":"Old","path":".github/workflows/ci.yml","state":"disabled_manually"}"#),
            "/repos/AttilaTheFun/shireworks/actions/workflows/14": (200, #"{"id":14,"name":"Release","path":".github/workflows/release.yml","state":"active"}"#),
        ])
        var rules = GateRules.standard
        rules.dispatchableWorkflows = ["ci.yml"]
        let dispatched = await check(github, .dispatch(repository: repo, workflow: 12, branch: "feature"), rules: rules)
        XCTAssertEqual(dispatched, .pass(nil))
        refused(await check(github, .dispatch(repository: repo, workflow: 14, branch: "feature"), rules: rules), "isn't among the workflows")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "feature")), "isn't among the workflows")
        refused(await check(github, .dispatch(repository: repo, workflow: 13, branch: "feature"), rules: rules), "disabled_manually")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "develop"), rules: rules), "default branch")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "gone"), rules: rules), "gone is not a branch")
        // NCH's follow-up to #417: the default branch however it's spelled, and never a tag.
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "heads/develop"), rules: rules), "default branch")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "refs/heads/Develop"), rules: rules), "default branch")
        refused(await check(github, .dispatch(repository: repo, workflow: 12, branch: "tags/v1"), rules: rules), "never tags/v1")
        let spelledOut = await check(github, .dispatch(repository: repo, workflow: 12, branch: "refs/heads/feature"), rules: rules)
        XCTAssertEqual(spelledOut, .pass(nil))
        XCTAssertEqual(GateChecker.branchName("refs/heads/a/b"), "a/b")
        XCTAssertEqual(GateChecker.branchName("heads/x"), "x")
        XCTAssertEqual(GateChecker.branchName("feature"), "feature")
    }

    // MARK: Release proposals on main (NCH's conditions, 26 Nov 2026)

    private let visor = "AttilaTheFun/visor"

    /// Visor's and Applications' GitHub: main the default, ci.yml (12) and
    /// release.yml (14) active, an old ci.yml (13) disabled; branch feature.
    private func proposals() -> FakeGitHub {
        var answers: [String: (Int, String)] = [:]
        for repository in ["AttilaTheFun/visor", "AttilaTheFun/applications"] {
            answers["/repos/\(repository)"] = (200, #"{"default_branch":"main"}"#)
            answers["/repos/\(repository)/actions/workflows/12"] = (200, #"{"id":12,"name":"CI","path":".github/workflows/ci.yml","state":"active"}"#)
            answers["/repos/\(repository)/actions/workflows/13"] = (200, #"{"id":13,"name":"Old","path":".github/workflows/ci.yml","state":"disabled_manually"}"#)
            answers["/repos/\(repository)/actions/workflows/14"] = (200, #"{"id":14,"name":"Release","path":".github/workflows/release.yml","state":"active"}"#)
            answers["/repos/\(repository)/git/ref/heads/feature"] = (200, "{\"object\":{\"sha\":\"\(head)\"}}")
        }
        return FakeGitHub(answers: answers)
    }

    private func proposing(_ inputs: [String: String], workflow: Int = 12, branch: String = "main", repository: String? = nil,
                           rules: GateRules = .standard, throttle: DispatchThrottle = DispatchThrottle()) async -> GateChecker.DispatchFinding {
        await GateChecker(rules: rules, github: proposals(), throttle: throttle)
            .dispatch(repository ?? visor, workflow, branch: branch, inputs: inputs)
    }

    /// The standard rules: Visor's ci.yml on main with run one of verify,
    /// prerelease and release, and nothing else: no other input, no other
    /// value, none left out, no other workflow or repository.
    func testOnMainADispatchIsTheListedWorkflowWithItsListedInputs() async {
        for run in ["verify", "prerelease", "release"] {
            let found = await proposing(["run": run])
            XCTAssertEqual(found, GateChecker.DispatchFinding(outcome: .pass(nil), workflowPath: ".github/workflows/ci.yml", onDefaultBranch: true))
        }
        let spelled = await proposing(["run": "release"], branch: "refs/heads/main")
        XCTAssertEqual(spelled.outcome, .pass(nil))
        // An input outside its list, left out, or another beside it.
        refused(await proposing(["run": "agent-image"]).outcome, "CI's run on main is one of verify, prerelease, release, never another value")
        refused(await proposing(["run": "populate"]).outcome, "never another value")
        refused(await proposing(["run": "Release"]).outcome, "never another value")
        refused(await proposing([:]).outcome, "is dispatched with run given: one of verify, prerelease, release")
        refused(await proposing(["run": "release", "extra": "x"]).outcome, "takes no input extra: only run (verify, prerelease, release)")
        refused(await proposing(["kind": "quick"]).outcome, "takes no input kind")
        // Another workflow, a disabled one, another repository's.
        refused(await proposing(["run": "release"], workflow: 14).outcome, "Release (.github/workflows/release.yml) isn't among the workflows dispatched on main")
        refused(await proposing(["run": "release"], workflow: 13).outcome, "disabled_manually")
        refused(await proposing(["run": "release"], repository: "AttilaTheFun/applications").outcome, "isn't among the workflows dispatched on main")
        // A refusal never echoes the value it refused.
        guard case .refuse(let reason) = await proposing(["run": "ghp_notatoken"]).outcome else { return XCTFail("not refused") }
        XCTAssertFalse(reason.contains("ghp_notatoken"), reason)
    }

    /// Exact match: listed by its file's name or path for branches, a
    /// workflow is still never dispatched on main; mainDispatch's entry is
    /// one repository's.
    func testOnMainAWorkflowIsNamedExactlyByItsRepository() async {
        var loose = GateRules.standard
        loose.dispatchableWorkflows = ["ci.yml", ".github/workflows/ci.yml", "AttilaTheFun/visor:.github/workflows/ci.yml"]
        loose.mainDispatch = .off
        refused(await proposing(["run": "release"], rules: loose).outcome, "dispatched on main, AttilaTheFun/visor's default branch")
        refused(await proposing(["run": "release"], rules: loose).outcome, "gate.json's mainDispatch, each as owner/name:path")
        loose.mainDispatch = GateRules.MainDispatch(perHour: 4, workflows: ["AttilaTheFun/applications:.github/workflows/ci.yml": ["run": ["verify"]]])
        refused(await proposing(["run": "verify"], rules: loose).outcome, "isn't among the workflows dispatched on main")
        let theirs = await proposing(["run": "verify"], repository: "AttilaTheFun/applications", rules: loose)
        XCTAssertEqual(theirs.outcome, .pass(nil))
        // A protected branch that isn't the default: never.
        var master = GateRules.standard
        master.dispatchableWorkflows = ["ci.yml"]
        let found = await GateChecker(rules: master, github: FakeGitHub(answers: [
            "/repos/AttilaTheFun/visor": (200, #"{"default_branch":"main"}"#),
            "/repos/AttilaTheFun/visor/actions/workflows/12": (200, #"{"id":12,"name":"CI","path":".github/workflows/ci.yml","state":"active"}"#),
            "/repos/AttilaTheFun/visor/git/ref/heads/master": (200, "{\"object\":{\"sha\":\"\(head)\"}}"),
        ])).dispatch(visor, 12, branch: "master", inputs: ["run": "release"])
        refused(found.outcome, "never dispatched on master, a protected branch")
        XCTAssertEqual(found.onDefaultBranch, false)
    }

    /// On a branch of the agent's own, today's rules: a listed workflow,
    /// any inputs (within the gate's limits, GitHubGateTests), the lists
    /// of main's never asked.
    func testABranchsDispatchIsAsBefore() async {
        let applications = "AttilaTheFun/applications"
        var rules = GateRules.standard
        rules.dispatchableWorkflows = ["ci.yml"]
        let any = await proposing(["run": "agent-image", "other": "x"], branch: "feature", repository: applications, rules: rules)
        XCTAssertEqual(any, GateChecker.DispatchFinding(outcome: .pass(nil), workflowPath: ".github/workflows/ci.yml", onDefaultBranch: false))
        let none = await proposing([:], branch: "feature", repository: applications, rules: rules)
        XCTAssertEqual(none.outcome, .pass(nil))
        refused(await proposing(["run": "verify"], branch: "feature", repository: applications).outcome, "isn't among the workflows an agent dispatches")
        refused(await proposing(["run": "verify"], workflow: 14, branch: "feature", repository: applications, rules: rules).outcome,
                "isn't among the workflows an agent dispatches")
        refused(await proposing([:], branch: "gone", repository: applications, rules: rules).outcome, "gone is not a branch")
        // Never counted against main's.
        let throttle = DispatchThrottle()
        rules.mainDispatch.perHour = 1
        for _ in 0..<3 { _ = await proposing([:], branch: "feature", repository: applications, rules: rules, throttle: throttle) }
        let main = await proposing(["run": "verify"], rules: rules, throttle: throttle)
        XCTAssertEqual(main.outcome, .pass(nil))
    }

    /// NCH's review of #557: on a branch, Visor's ci.yml with run verify
    /// alone (branchDispatch, the standard rules'): never prerelease or
    /// release off main, never agent-image, nothing left out or added; held
    /// to its list even where dispatchableWorkflows lists its file.
    func testOnAVisorBranchCIIsVerifyAlone() async {
        let verify = await proposing(["run": "verify"], branch: "feature")
        XCTAssertEqual(verify, GateChecker.DispatchFinding(outcome: .pass(nil), workflowPath: ".github/workflows/ci.yml", onDefaultBranch: false))
        for run in ["agent-image", "prerelease", "release", "populate", "container-apple"] {
            refused(await proposing(["run": run], branch: "feature").outcome, "CI's run on feature is one of verify, never another value")
        }
        refused(await proposing([:], branch: "feature").outcome, "CI on feature is dispatched with run given: one of verify")
        refused(await proposing(["run": "verify", "extra": "x"], branch: "feature").outcome, "CI on feature takes no input extra: only run (verify)")
        var loose = GateRules.standard
        loose.dispatchableWorkflows = ["ci.yml", ".github/workflows/ci.yml"]
        refused(await proposing(["run": "agent-image"], branch: "feature", rules: loose).outcome, "never another value")
        let stillVerify = await proposing(["run": "verify"], branch: "feature", rules: loose)
        XCTAssertEqual(stillVerify.outcome, .pass(nil))
        // Another of its workflows, unlisted: not dispatched; one dispatchableWorkflows lists, with any inputs.
        refused(await proposing(["run": "verify"], workflow: 14, branch: "feature").outcome, "isn't among the workflows an agent dispatches")
        loose.dispatchableWorkflows = ["release.yml"]
        let release = await proposing(["anything": "x"], workflow: 14, branch: "feature", rules: loose)
        XCTAssertEqual(release.outcome, .pass(nil))
        // Its list is its repository's alone.
        refused(await proposing(["run": "verify"], branch: "feature", repository: "AttilaTheFun/applications").outcome, "isn't among the workflows")
        XCTAssertEqual(GateChecker.inputsRefusal("CI", on: "x", allowed: ["run": ["verify"]], given: ["run": "verify"]), nil)
    }

    /// At most perHour (four) of a repository's an hour, counted by the
    /// gate; the next refused saying when; another repository's apart;
    /// refusals uncounted.
    func testMainDispatchesAreThrottledPerRepositoryPerHour() async {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let throttle = DispatchThrottle(now: { clock.withLock { $0 } })
        var rules = GateRules.standard
        rules.mainDispatch.workflows["AttilaTheFun/applications:.github/workflows/ci.yml"] = ["run": ["verify"]]
        refused(await proposing(["run": "publish"], rules: rules, throttle: throttle).outcome, "never another value")
        for _ in 0..<4 {
            let found = await proposing(["run": "release"], rules: rules, throttle: throttle)
            XCTAssertEqual(found.outcome, .pass(nil))
        }
        refused(await proposing(["run": "verify"], rules: rules, throttle: throttle).outcome,
                "AttilaTheFun/visor has had 4 dispatches on main in the last hour, the most gate.json's mainDispatch.perHour lets through: the next in 60 minutes")
        let other = await proposing(["run": "verify"], repository: "AttilaTheFun/applications", rules: rules, throttle: throttle)
        XCTAssertEqual(other.outcome, .pass(nil), "another repository's are counted apart")
        clock.withLock { $0 += 59 * 60 + 30 }
        refused(await proposing(["run": "verify"], rules: rules, throttle: throttle).outcome, "the next in 1 minute")
        XCTAssertNotNil(throttle.take("attilathefun/VISOR", limit: 4), "the repository by any case, and a refusal isn't counted")
        clock.withLock { $0 += 30 }
        let again = await proposing(["run": "verify"], rules: rules, throttle: throttle)
        XCTAssertEqual(again.outcome, .pass(nil), "an hour on")
        // perHour 0: none.
        rules.mainDispatch.perHour = 0
        refused(await proposing(["run": "verify"], rules: rules).outcome, "has had 0 dispatches")
    }

    /// A run still going, as a cancel reads it.
    private func going(event: String = "pull_request", branch: String? = "feature", headRepo: String = "AttilaTheFun/shireworks") -> String {
        let named = branch.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":77,"name":"CI","event":"\(event)","status":"in_progress","head_branch":\(named),
         "head_sha":"\(head)","head_repository":{"full_name":"\(headRepo)"}}
        """
    }

    /// NCH's review of #557: an agent cancels a run only on a branch of its
    /// own, as a push's own branch is told (GateRules' isOwn): never on the
    /// default branch or main, whatever its event and whatever gate.json
    /// says; never a fork's, a protected branch's, or one outside
    /// ownBranchPrefixes.
    func testAnAgentCancelsARunOnlyOnABranchOfItsOwn() async {
        let cancel = GateCheck.cancel(repository: repo, run: 77)
        var loose = GateRules.standard
        loose.protectedBranches = []
        loose.protectDefaultBranch = false
        loose.mainDispatch = GateRules.MainDispatch(perHour: 100, workflows: ["AttilaTheFun/shireworks:.github/workflows/ci.yml": ["run": ["x"]]])
        for event in ["push", "workflow_dispatch", "schedule", "pull_request"] {
            refused(await check(runs(going(event: event, branch: "main")), cancel, rules: loose), "is on main, AttilaTheFun/shireworks's default branch or main: an agent never cancels a run there")
            refused(await check(runs(going(event: event, branch: "Main")), cancel), "never cancels a run there")
        }
        // The default branch by another name, and main that isn't the default.
        let develop = ["/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"develop"}"#)]
        refused(await check(runs(going(event: "push", branch: "develop"), extra: develop), cancel, rules: loose), "is on develop")
        refused(await check(runs(going(event: "push", branch: "main"), extra: develop), cancel, rules: loose), "never cancels a run there")
        // A protected branch, a fork's, a tag's run (no branch).
        refused(await check(runs(going(event: "push", branch: "master")), cancel), "not one of the agent's own branches")
        refused(await check(runs(going(headRepo: "someone/shireworks")), cancel), "commit is in another repository")
        refused(await check(runs(going(event: "push", branch: nil)), cancel), "is on no branch")
        // Its own: any branch not protected, or of ownBranchPrefixes when it lists any.
        let own = await check(runs(going()), cancel)
        XCTAssertEqual(own, .pass(nil))
        let dispatched = await check(runs(going(event: "workflow_dispatch")), cancel)
        XCTAssertEqual(dispatched, .pass(nil))
        var prefixed = GateRules.standard
        prefixed.ownBranchPrefixes = ["agent/"]
        refused(await check(runs(going()), cancel, rules: prefixed), "not one of the agent's own branches")
        let agents = await check(runs(going(branch: "agent/fix")), cancel, rules: prefixed)
        XCTAssertEqual(agents, .pass(nil))
        // A release's, and its default branch unread: no cancel.
        refused(await check(runs(going(event: "release", branch: "v1.0")), cancel), "its publishing must finish")
        guard case .fail = await check(runs(going(), extra: ["/repos/AttilaTheFun/shireworks": (500, "{}")]), cancel) else {
            return XCTFail("cancelled unread")
        }
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

    // MARK: Closing an agent's own (Logan, 25 Nov 2026)

    private var bot: GitHubAppIdentity { GitHubAppIdentity(slug: "logan-shire-agent", userID: 987) }

    private func issue(_ number: Int, by login: String, pull: Bool) -> FakeGitHub {
        let marked = pull ? #","pull_request":{"url":"x"}"# : ""
        return FakeGitHub(answers: ["/repos/AttilaTheFun/shireworks/issues/\(number)":
            (200, #"{"number":\#(number),"user":{"login":"\#(login)"}\#(marked)}"#)])
    }

    private func node(_ kind: String, author: String, login: String, repository: String = "AttilaTheFun/shireworks") -> FakeGitHub {
        FakeGitHub(answers: ["graphql node": (200, #"{"data":{"node":{"__typename":"\#(kind)","number":7,"author":{"__typename":"\#(author)","login":"\#(login)"},"repository":{"nameWithOwner":"\#(repository)"}}}}"#)])
    }

    func testAnAgentClosesOnlyWhatTheAppsBotOpened() async {
        let close = GateCheck.close(repository: repo, number: 7)
        for pull in [true, false] {
            let own = await GateChecker(rules: .standard, github: issue(7, by: "logan-shire-agent[bot]", pull: pull), bot: bot).run(close)
            XCTAssertEqual(own, .pass(nil))
            let logans = await GateChecker(rules: .standard, github: issue(7, by: "AttilaTheFun", pull: pull), bot: bot).run(close)
            refused(logans, "\(pull ? "pull request" : "issue") #7 of AttilaTheFun/shireworks is AttilaTheFun's: an agent closes only what it opened itself")
            // The auth token's: no bot to be.
            let unknown = await GateChecker(rules: .standard, github: issue(7, by: "logan-shire-agent[bot]", pull: pull)).run(close)
            refused(unknown, "with no GitHub App")
        }
        // Another App's bot isn't this one.
        let other = await GateChecker(rules: .standard, github: issue(7, by: "dependabot[bot]", pull: true), bot: bot).run(close)
        refused(other, "dependabot[bot]'s")
        let missing = await GateChecker(rules: .standard, github: FakeGitHub(answers: [:]), bot: bot).run(close)
        XCTAssertEqual(missing, .fail("GitHub didn't give #7 of AttilaTheFun/shireworks (404)"))
    }

    func testAGraphQLCloseReadsItsNodesAuthor() async {
        let bot = self.bot
        let checker = { (github: FakeGitHub) in GateChecker(rules: .standard, github: github, bot: bot) }
        for kind in ["PullRequest", "Issue"] {
            let own = await checker(node(kind, author: "Bot", login: "logan-shire-agent")).run(.graphQLClose(id: "N_1", kind: kind))
            XCTAssertEqual(own, .pass(nil), kind)
            let logans = await checker(node(kind, author: "User", login: "AttilaTheFun")).run(.graphQLClose(id: "N_1", kind: kind))
            refused(logans, "#7 of AttilaTheFun/shireworks is AttilaTheFun's")
            let unknown = await GateChecker(rules: .standard, github: node(kind, author: "Bot", login: "logan-shire-agent"))
                .run(.graphQLClose(id: "N_1", kind: kind))
            refused(unknown, "with no GitHub App")
            let elsewhere = await checker(node(kind, author: "Bot", login: "logan-shire-agent", repository: "someone/else"))
                .run(.graphQLClose(id: "N_1", kind: kind))
            refused(elsewhere, "not among the repositories")
        }
        // A user who happens to have the slug for a login isn't the bot.
        let namesake = await checker(node("Issue", author: "User", login: "logan-shire-agent")).run(.graphQLClose(id: "N_1", kind: "Issue"))
        refused(namesake, "is logan-shire-agent's")
        let wrongKind = await checker(node("Issue", author: "Bot", login: "logan-shire-agent")).run(.graphQLClose(id: "N_1", kind: "PullRequest"))
        refused(wrongKind, "is a Issue, not a PullRequest")
        let none = await checker(FakeGitHub(answers: ["graphql node": (200, #"{"data":{"node":null}}"#)])).run(.graphQLClose(id: "N_1", kind: "Issue"))
        refused(none, "no node the agent proxy can see")
    }

    func testAPushNeverReachesTheDefaultBranch() async {
        let github = FakeGitHub(answers: ["/repos/AttilaTheFun/shireworks": (200, #"{"default_branch":"develop"}"#)])
        let feature = await check(github, .push(repository: repo, branches: ["feature"]))
        XCTAssertEqual(feature, .pass(nil))
        refused(await check(github, .push(repository: repo, branches: ["feature", "Develop"])), "default branch")
    }
}
