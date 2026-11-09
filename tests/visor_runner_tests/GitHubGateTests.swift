// GitHubGate (docs/github-proxy.md, docs/github-gate-rules.md): gh_mcp's
// guards as the proxy's policy. Its tests ported as request → verdict
// (`policyRefusesWhatGoesThroughLogan`, line by line, and the others the spec
// marks "proxy"), with Logan's decisions of 7 Nov: return_run_details is
// allowed, and GraphQL's mergePullRequest is checked as the REST merge.

import Foundation
@testable import VisorRunner
import XCTest

final class GitHubGateTests: XCTestCase {
    private let gate = GitHubGate()
    private let sha = String(repeating: "a", count: 40)
    private let repo = "/repos/AttilaTheFun/oss"

    private func rest(_ method: String, _ path: String, _ body: String? = nil) -> GateDecision {
        gate.decide(GateRequest(method: method, host: "api.github.com", target: path, body: body.map { Data($0.utf8) }))
    }

    private func graphQL(_ query: String, variables: String = "null", operation: String? = nil) -> GateDecision {
        let named = operation.map { ",\"operationName\":\"\($0)\"" } ?? ""
        let body = "{\"query\":\(Self.quoted(query)),\"variables\":\(variables)\(named)}"
        return gate.decide(GateRequest(method: "POST", host: "api.github.com", target: "/graphql", body: Data(body.utf8)))
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    private func refused(_ decision: GateDecision, _ containing: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .refuse(let reason) = decision else { return XCTFail("not refused: \(decision)", file: file, line: line) }
        if !containing.isEmpty { XCTAssertTrue(reason.contains(containing), reason, file: file, line: line) }
    }

    private func passes(_ decision: GateDecision, file: StaticString = #filePath, line: UInt = #line) {
        if case .refuse(let reason) = decision { XCTFail("refused: \(reason)", file: file, line: line) }
    }

    // MARK: Repositories and paths ([R1], [R2], §3)

    func testRepositoriesAreTheAllowedOnesCaseInsensitively() {
        var rules = GateRules.standard
        rules.repositories = ["AttilaTheFun/*", "other/one"]
        XCTAssertTrue(rules.allows("attilathefun/visor"))
        XCTAssertTrue(rules.allows("Other/One"))
        XCTAssertFalse(rules.allows("other/two"))
        XCTAssertFalse(rules.allows("someone/else"))
        XCTAssertFalse(rules.allows("not a repo"))
        passes(rest("GET", "/repos/attilathefun/OSS/pulls/3/comments"))
        XCTAssertEqual(rest("GET", "/repos/attilathefun/OSS/pulls/3"), .allow(repository: "attilathefun/OSS"))
        // Outside them, a read goes on anonymously; a write never does.
        XCTAssertEqual(rest("GET", "/repos/someone/else/pulls"), .anonymous(repository: "someone/else"))
        refused(rest("POST", "/repos/someone/else/issues/1/comments", #"{"body":"x"}"#), "not among the repositories")
    }

    /// Logan, 9 Nov 2026: a public repository outside the allowed ones is read
    /// with no token (a clone of an open-source dependency, its REST reads),
    /// and nothing else of it goes through.
    func testOutsideTheAllowedRepositoriesOnlyReadsGoOnAndWithNoToken() {
        let git = { (method: String, target: String, body: String?) in
            self.gate.decide(GateRequest(method: method, host: "github.com", target: target, body: body.map { Data($0.utf8) }))
        }
        let outside = GateDecision.anonymous(repository: "swiftlang/swift-foundation")
        // A clone and a fetch: refs, then the pack.
        XCTAssertEqual(git("GET", "/swiftlang/swift-foundation.git/info/refs?service=git-upload-pack", nil), outside)
        XCTAssertEqual(git("POST", "/swiftlang/swift-foundation.git/git-upload-pack", "0000"), outside)
        XCTAssertEqual(git("POST", "/swiftlang/swift-foundation.git/info/lfs/objects/batch", #"{"operation":"download"}"#), outside)
        // Its REST reads.
        XCTAssertEqual(rest("GET", "/repos/swiftlang/swift-foundation/tags"), outside)
        XCTAssertEqual(rest("HEAD", "/repos/swiftlang/swift-foundation"), outside)
        // Never a push, the push side of git, an LFS upload, or a REST write.
        refused(git("GET", "/swiftlang/swift-foundation.git/info/refs?service=git-receive-pack", nil), "not among")
        refused(git("POST", "/swiftlang/swift-foundation.git/git-receive-pack", "0000"), "not among")
        refused(git("POST", "/swiftlang/swift-foundation.git/info/lfs/objects/batch", #"{"operation":"upload"}"#), "not among")
        refused(rest("POST", "/repos/swiftlang/swift-foundation/issues", #"{"title":"x"}"#), "not among")
        refused(rest("PATCH", "/repos/swiftlang/swift-foundation/pulls/1", #"{"title":"x"}"#), "not among")
        refused(rest("DELETE", "/repos/swiftlang/swift-foundation"), "not among the writes")
        // What names no repository is still no read.
        refused(rest("GET", "/repos/not%20a/repo"), "not a repository")
    }

    /// A release's asset and a ref's archive, as Bazel and SwiftPM download
    /// them: anonymously outside the allowed repositories, with the token for
    /// theirs, and never written to (Logan, 9 Nov 2026).
    func testReleaseAssetsAndArchivesAreDownloadedAnonymouslyOutside() {
        let web = { (method: String, target: String) in
            self.gate.decide(GateRequest(method: method, host: "github.com", target: target))
        }
        let platforms = GateDecision.anonymous(repository: "bazelbuild/platforms")
        XCTAssertEqual(web("GET", "/bazelbuild/platforms/releases/download/1.1.0/platforms-1.1.0.tar.gz"), platforms)
        XCTAssertEqual(web("HEAD", "/bazelbuild/platforms/releases/download/1.1.0/platforms-1.1.0.tar.gz"), platforms)
        XCTAssertEqual(web("GET", "/bazelbuild/platforms/archive/refs/tags/1.1.0.tar.gz"), platforms)
        XCTAssertEqual(web("GET", "/bazelbuild/platforms/archive/0123abc.zip"), platforms)
        // An allowed repository's: with the token.
        XCTAssertEqual(web("GET", "/AttilaTheFun/visor/releases/download/v0.47.1/builds.json"), .allow(repository: "AttilaTheFun/visor"))
        XCTAssertEqual(web("GET", "/AttilaTheFun/visor/archive/refs/tags/v0.47.1.tar.gz"), .allow(repository: "AttilaTheFun/visor"))
        // Never an upload or a write to them, and no other web page.
        refused(web("POST", "/bazelbuild/platforms/releases/download/1.1.0/platforms-1.1.0.tar.gz"), "")
        refused(web("PUT", "/AttilaTheFun/visor/releases/download/v0.47.1/builds.json"), "")
        refused(web("GET", "/bazelbuild/platforms/releases/download/1.1.0"), "")
        refused(web("GET", "/bazelbuild/platforms/releases"), "")
        refused(web("GET", "/bazelbuild/platforms/settings"), "")
        refused(web("GET", "/not%20a/repo/archive/x.zip"), "")
    }

    func testAPathCantClimbOutOfItsRepository() {
        refused(rest("GET", "/repos/AttilaTheFun/x/../../repos/someone/else"), "no plain path")
        refused(rest("GET", "/repos/AttilaTheFun/x/%2e%2e/y"), "no plain path")
        refused(rest("GET", "/repos/AttilaTheFun/x/a%2Fb"), "no plain path")
        refused(rest("GET", "/repos//AttilaTheFun/x"), "no plain path")
        refused(rest("GET", "/orgs/AttilaTheFun/members"), "outside")
        passes(rest("GET", "/repos/AttilaTheFun/oss/contents/docs/my%20file.md?ref=main"))
        passes(rest("GET", "/rate_limit"))
        passes(rest("GET", "/repositories/123/pulls"))
    }

    func testAWritesBodyIsOneObjectEachKeyOnceAndNoQuery() {
        refused(rest("POST", "\(repo)/issues/3/comments", #"{"body":"a","body":"b"}"#), "each key once")
        refused(rest("POST", "\(repo)/issues/3/comments", #"["body"]"#), "each key once")
        refused(rest("POST", "\(repo)/issues/3/comments?state=closed", #"{"body":"a"}"#), "query string")
        passes(rest("POST", "\(repo)/issues/3/comments", #"{"body":"a"}"#))
    }

    // MARK: policyRefusesWhatGoesThroughLogan

    func testWhatGoesThroughLoganIsRefused() {
        let cases: [(String, String, String?)] = [
            ("PUT", "\(repo)/pulls/3/merge", nil),                                                         // 338
            ("PUT", "\(repo)/pulls/3/merge", #"{"merge_method":"squash"}"#),                               // 339
            ("PUT", "\(repo)/pulls/3/merge", #"{"merge_method":"squash","sha":"main"}"#),                  // 340
            ("PUT", "\(repo)/pulls/3/merge", "{\"merge_method\":\"fast-forward\",\"sha\":\"\(sha)\"}"),     // 341
            ("PUT", "\(repo)/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\",\"admin\":true}"),          // 342
            ("PUT", "\(repo)/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\",\"delete_branch\":true}"),  // 343
            ("POST", "\(repo)/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"),        // 344
            ("PUT", "/repos/someone/else/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"), // 345
            ("POST", "\(repo)/merges", #"{"base":"main","head":"x"}"#),                                    // 346
            ("PUT", "\(repo)/pulls/3/update-branch", nil),                                                 // 347
            ("PUT", "\(repo)/pulls/3/update-branch", "{\"expected_head_sha\":\"\(sha)\",\"update_method\":\"rebase\"}"), // 348
            ("PATCH", "\(repo)/pulls/3", #"{"state":"closed"}"#),                                          // 349
            ("PATCH", "\(repo)/issues/3", #"{"state":"closed"}"#),                                         // 350
            ("POST", "\(repo)/pulls/3/reviews", #"{"event":"APPROVE"}"#),                                  // 351
            ("POST", "\(repo)/pulls/3/reviews", #"{"event":"REQUEST_CHANGES","body":"x"}"#),               // 352
            ("POST", "\(repo)/releases", #"{"tag_name":"v1","draft":false}"#),                             // 353
            ("PATCH", "\(repo)/releases/9", #"{"draft":false}"#),                                          // 354
            ("PATCH", "\(repo)/releases/9", #"{"make_latest":"true"}"#),                                   // 355
            ("DELETE", "\(repo)/git/refs/heads/x", nil),                                                   // 356
            ("DELETE", "\(repo)/issues/comments/5", nil),                                                  // 357
            ("POST", "\(repo)/git/refs", "{\"ref\":\"refs/tags/v1\",\"sha\":\"\(sha)\"}"),                // 358
            ("POST", "\(repo)/actions/runs/1/rerun-failed-jobs", #"{"enable_debug_logging":true}"#),      // 359
            ("POST", "\(repo)/actions/runs/1/rerun", #"{"enable_debug_logging":true}"#),                  // 360
            ("POST", "\(repo)/actions/runs/1/force-cancel", nil),                                          // 361
            ("POST", "\(repo)/actions/runs/1/approve", nil),                                               // 362
            ("POST", "\(repo)/actions/jobs/1/rerun", nil),                                                 // 363
            ("DELETE", "\(repo)/actions/runs/1", nil),                                                     // 364
            ("DELETE", "\(repo)/actions/runs/1/logs", nil),                                                // 365
            ("PUT", "\(repo)/actions/permissions", #"{"enabled":false}"#),                                 // 366
            ("POST", "/repos/someone/else/actions/runs/1/cancel", nil),                                    // 367
            ("POST", "\(repo)/actions/runs/main/rerun", nil),                                              // 368
            ("POST", "\(repo)/actions/workflows/ci.yml/dispatches", #"{"ref":"main"}"#),                   // 369
            ("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"refs/tags/v1"}"#),               // 370
            ("PUT", "\(repo)/branches/main/protection", #"{"enforce_admins":false}"#),                     // 372
            ("PUT", "\(repo)/actions/secrets/X", #"{"encrypted_value":"x"}"#),                             // 373
            ("PATCH", repo, #"{"private":false}"#),                                                        // 374
            ("POST", "/repos/someone/else/issues", #"{"title":"x"}"#),                                     // 377
        ]
        for (method, path, body) in cases {
            if case .refuse = rest(method, path, body) { continue }
            XCTFail("not refused: \(method) \(path) \(body ?? "")")
        }
        // gh_mcp's 376 refused a read outside the allowed repositories; the
        // proxy reads it anonymously, with no token (Logan, 9 Nov 2026).
        XCTAssertEqual(rest("GET", "/repos/someone/else/issues"), .anonymous(repository: "someone/else"))
    }

    func testWhatAgentsDoIsAllowed() {
        passes(rest("GET", "\(repo)/pulls/3/comments"))                                                    // 379
        passes(rest("POST", "\(repo)/pulls/3/reviews", #"{"event":"COMMENT","body":"Looks right"}"#))      // 380
        passes(rest("PATCH", "\(repo)/issues/3", #"{"title":"t","labels":["bug","ui"]}"#))                // 381
        passes(rest("POST", "\(repo)/pulls/3/comments/7/replies", #"{"body":"Done"}"#))                   // 382
        XCTAssertEqual(rest("PUT", "\(repo)/pulls/3/merge",                                                 // 384-385
                            "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\",\"commit_title\":\"t\",\"commit_message\":\"m\"}"),
                       .check(.merge(repository: "AttilaTheFun/oss", number: 3, sha: sha, method: "squash")))
        XCTAssertEqual(rest("PUT", "\(repo)/pulls/3/update-branch", "{\"expected_head_sha\":\"\(sha)\"}"),    // 386
                       .check(.updateBranch(repository: "AttilaTheFun/oss", number: 3)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/rerun-failed-jobs"),                            // 387
                       .check(.rerun(repository: "AttilaTheFun/oss", run: 1, failedOnly: true)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/rerun", "{}"),                                  // 388
                       .check(.rerun(repository: "AttilaTheFun/oss", run: 1, failedOnly: false)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/cancel"), .check(.cancel(repository: "AttilaTheFun/oss", run: 1))) // 389
        XCTAssertEqual(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main","inputs":{"kind":"quick"}}"#), // 390
                       .check(.dispatch(repository: "AttilaTheFun/oss", workflow: 12, branch: "main")))
        // 371, now allowed: gh workflow run sends it, and GitHub answers the run.
        passes(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main","return_run_details":true}"#))
    }

    func testReleasesAreDraftsOnly() {
        passes(rest("POST", "\(repo)/releases", #"{"tag_name":"v1.1","target_commitish":"main","name":"1.1","body":"","draft":true}"#))
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1.1"}"#), "a draft only")
        XCTAssertEqual(rest("PATCH", "\(repo)/releases/9", #"{"body":"new"}"#), .check(.releaseEdit(repository: "AttilaTheFun/oss", release: 9)))
        refused(rest("PATCH", "\(repo)/releases/9", #"{"body":"new","prerelease":true}"#), "never sends prerelease")
    }

    func testDispatchInputsAreAFewOneLineStrings() {
        refused(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main","inputs":"kind=quick"}"#), "JSON object of strings")
        refused(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main","inputs":{"kind":"one\ntwo"}}"#), "one line")
        refused(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main","inputs":{"a b":"x"}}"#), "input's name")
    }

    func testAPullRequestIsBetweenTwoBranchesOfTheRepository() {
        passes(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"feature","base":"main","body":"","draft":false}"#))
        passes(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"AttilaTheFun:feature","base":"main"}"#))
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"someone:feature","base":"main"}"#), "a branch of AttilaTheFun's")
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"main","base":"main"}"#), "the same branch")
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"feature","base":"main","maintainer_can_modify":true}"#), "never sends")
    }

    // MARK: GraphQL (§3.2)

    func testQueriesPassAndGhsWritesAreCheckedByTheirNodes() {
        passes(graphQL("query PullRequestStatus { repository(owner: \"AttilaTheFun\", name: \"oss\") { pullRequests(first: 5) { nodes { number } } } }"))
        passes(graphQL("{ viewer { login } }"))
        // gh pr ready, as githubv4 writes it.
        XCTAssertEqual(graphQL("mutation PullRequestReadyForReview($input:MarkPullRequestReadyForReviewInput!){markPullRequestReadyForReview(input: $input){clientMutationId}}",
                               variables: #"{"input":{"pullRequestId":"PR_kw1"}}"#),
                       .check(.graphQLNodes([.init(id: "PR_kw1", kinds: ["PullRequest"])])))
        // gh pr create always sends maintainerCanModify.
        XCTAssertEqual(graphQL("mutation PullRequestCreate($input:CreatePullRequestInput!){createPullRequest(input:$input){pullRequest{id}}}",
                               variables: #"{"input":{"repositoryId":"R_1","baseRefName":"main","headRefName":"feature","title":"t","body":"","draft":false,"maintainerCanModify":true}}"#),
                       .check(.graphQLNodes([.init(id: "R_1", kinds: ["Repository"])])))
        // An alias doesn't hide a field, nor does an inline input.
        refused(graphQL("mutation { ok: deleteRef(input: {refId: \"REF_1\"}) { clientMutationId } }"), "nothing is deleted")
        refused(graphQL("mutation { updateIssue(input: {id: \"I_1\", state: CLOSED}) { clientMutationId } }"), "never sends state")
    }

    func testAMutationIsItsWrittenOutRootFieldsAlone() {
        refused(graphQL("mutation { ...M } fragment M on Mutation { deleteRef(input: {refId: \"x\"}) { clientMutationId } }"), "no fragments")
        refused(graphQL("mutation { closeIssue(input: {issueId: \"I_1\"}) { clientMutationId } }"), "closing and reopening")
        refused(graphQL("mutation { addComment(input: {subjectId: \"I_1\", body: \"x\"}) { clientMutationId } createRef(input: {repositoryId: \"R\", name: \"refs/heads/x\", oid: \"\(sha)\"}) { clientMutationId } }"),
                "pushed with git")
        refused(graphQL("query A { viewer { login } } mutation B { addComment(input: {subjectId: \"I\", body: \"x\"}) { clientMutationId } }"), "operationName")
        passes(graphQL("query A { viewer { login } } mutation B { addComment(input: {subjectId: \"I\", body: \"x\"}) { clientMutationId } }", operation: "A"))
        refused(graphQL("subscription { x }"), "subscriptions")
        refused(graphQL("mutation { addPullRequestReview(input: {pullRequestId: \"PR\", event: APPROVE}) { clientMutationId } }"), "COMMENT only")
    }

    func testGhPrMergeIsTheRESTMergeAndAutoMergeIsRefused() {
        XCTAssertEqual(graphQL("mutation PullRequestMerge($input:MergePullRequestInput!){mergePullRequest(input:$input){clientMutationId}}",
                               variables: #"{"input":{"pullRequestId":"PR_1","mergeMethod":"SQUASH","commitHeadline":"t"}}"#),
                       .check(.graphQLMerge(pullRequestID: "PR_1", method: "squash", variable: "input", expectedHeadOid: nil)))
        refused(graphQL("mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"), "no auto-merge")
        refused(graphQL("mutation { updatePullRequestBranch(input: {pullRequestId: \"PR_1\", expectedHeadOid: \"\(sha)\", updateMethod: REBASE}) { clientMutationId } }"),
                "never rebased")
        XCTAssertEqual(graphQL("mutation { updatePullRequestBranch(input: {pullRequestId: \"PR_1\", expectedHeadOid: \"\(sha)\", updateMethod: MERGE}) { clientMutationId } }"),
                       .check(.graphQLUpdateBranch(pullRequestID: "PR_1")))
    }

    // MARK: git (§3.3)

    private func pushList(_ lines: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for (index, line) in lines.enumerated() {
            let text = index == 0 ? line + "\0report-status side-band-64k\n" : line + "\n"
            bytes += Array(String(format: "%04x", text.utf8.count + 4).utf8) + Array(text.utf8)
        }
        return bytes + Array("0000".utf8)
    }

    private func push(_ lines: [String], repository: String = "AttilaTheFun/oss") -> GateDecision {
        let body = Data(pushList(lines) + Array("PACK".utf8))
        return gate.decide(GateRequest(method: "POST", host: "github.com", target: "/\(repository).git/git-receive-pack", body: body))
    }

    func testFetchesPassAndAPushIsCheckedByItsCommands() {
        passes(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/AttilaTheFun/oss.git/info/refs?service=git-upload-pack")))
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/oss/git-upload-pack")))
        XCTAssertEqual(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/someone/else.git/info/refs?service=git-upload-pack")),
                       .anonymous(repository: "someone/else"), "outside the allowed ones: anonymously")
        refused(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/login")), "only a repository's git")
        let zero = String(repeating: "0", count: 40)
        let other = String(repeating: "b", count: 40)
        XCTAssertEqual(push(["\(zero) \(sha) refs/heads/feature/x"]), .check(.push(repository: "AttilaTheFun/oss", branches: ["feature/x"])))
        // A forced update of one's own branch: Logan's choice ([G3f]).
        XCTAssertEqual(push(["\(other) \(sha) refs/heads/fix"]), .check(.push(repository: "AttilaTheFun/oss", branches: ["fix"])))
        refused(push(["\(other) \(sha) refs/heads/main"]), "never pushed")
        refused(push(["\(other) \(sha) refs/heads/Master"]), "never pushed")
        refused(push(["\(zero) \(sha) refs/tags/v1.0"]), "never tags")
        refused(push(["\(zero) \(sha) refs/heads/feature", "\(other) \(sha) refs/heads/main"]), "never pushed")
        refused(push(["\(sha) \(zero) refs/heads/feature"]), "never deleted")
        refused(push(["\(zero) \(sha) refs/heads/a..b"]), "not a branch name")
        refused(push(["\(zero) \(sha) refs/heads/x.lock"]), "not a branch name")
        refused(push(["\(zero) \(sha) refs/heads/feature"], repository: "someone/else"), "not among")
        // git's probe, a flush alone.
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/oss.git/git-receive-pack", body: Data("0000".utf8))))
        refused(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/oss.git/git-receive-pack",
                                        body: Data(pushList(["push-cert"])))), "signed pushes")
    }

    func testBranchNamesAreGits() {
        for good in ["feature/x", "fix", "release-0.47", "a.b"] { XCTAssertTrue(GitRefName.isBranch(good), good) }
        for bad in ["a..b", "x.lock", "a b", "x:y", "HEAD", "", "a/", ".hidden", "a/.b", "x@{y", "a\\b", "~x"] {
            XCTAssertFalse(GitRefName.isBranch(bad), bad)
        }
    }

    func testUploadsAndLFSWrites() {
        refused(gate.decide(GateRequest(method: "POST", host: "uploads.github.com", target: "/repos/AttilaTheFun/oss/releases/1/assets?name=x")))
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/oss.git/info/lfs/objects/batch",
                                       body: Data(#"{"operation":"download","objects":[]}"#.utf8))))
        refused(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/oss.git/info/lfs/objects/batch",
                                        body: Data(#"{"operation":"upload","objects":[]}"#.utf8))), "uploads")
    }
}
