// GitHubGate (MultiPass's docs/github-proxy.md, docs/github-gate-rules.md):
// gh_mcp's guards as agent-proxy's policy. Its tests ported as request →
// verdict (`policyRefusesWhatGoesThroughLogan`, line by line, and the others
// the spec marks "proxy"), with Logan's decisions of 7 Nov (return_run_details
// is allowed) and of 14 Nov 2026, as GitHub moved into agent-proxy: merging,
// publishing a release and deleting a ref are his alone, every way GitHub
// takes them (MultiPass checked a merge and let it through).

import Foundation
@testable import VisorAgentProxy
import XCTest

final class GitHubGateTests: XCTestCase {
    private let gate = GitHubGate()
    private let sha = String(repeating: "a", count: 40)
    private let repo = "/repos/AttilaTheFun/shireworks"

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
        passes(rest("GET", "/repos/attilathefun/SHIREWORKS/pulls/3/comments"))
        XCTAssertEqual(rest("GET", "/repos/attilathefun/SHIREWORKS/pulls/3"), .allow(repository: "attilathefun/SHIREWORKS"))
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

    /// Which requests only read, and may go on with no token when none is
    /// configured (Logan's container test, 25 Nov 2026: a clone of an
    /// allowed public repository): REST's GET and HEAD, a GraphQL query, a
    /// fetch or clone, an LFS download, an asset or archive. Never a push, a
    /// REST write, a mutation or an upload.
    func testReadsAreTheRequestsThatGoOnWithNoTokenConfigured() {
        let read = { (method: String, host: String, target: String, body: String?) in
            self.gate.isRead(GateRequest(method: method, host: host, target: target, body: body.map { Data($0.utf8) }))
        }
        let query = #"{"query":"query { repository(owner: \"AttilaTheFun\", name: \"swift_sql\") { name } }"}"#
        let mutation = #"{"query":"mutation { addComment(input: {subjectId: \"I_1\", body: \"x\"}) { clientMutationId } }"}"#
        XCTAssertTrue(read("GET", "api.github.com", "/repos/AttilaTheFun/swift_sql/pulls?state=open", nil))
        XCTAssertTrue(read("HEAD", "api.github.com", "/repos/AttilaTheFun/swift_sql", nil))
        XCTAssertTrue(read("GET", "api.github.com", "/search/issues?q=x", nil))
        XCTAssertTrue(read("POST", "api.github.com", "/graphql", query))
        XCTAssertTrue(read("GET", "github.com", "/AttilaTheFun/swift_sql.git/info/refs?service=git-upload-pack", nil))
        XCTAssertTrue(read("POST", "github.com", "/AttilaTheFun/swift_sql.git/git-upload-pack", "0000"))
        XCTAssertTrue(read("POST", "github.com", "/AttilaTheFun/swift_sql.git/info/lfs/objects/batch", #"{"operation":"download"}"#))
        XCTAssertTrue(read("GET", "github.com", "/AttilaTheFun/visor/releases/download/v0.47.1/builds.json", nil))
        XCTAssertTrue(read("GET", "github.com", "/AttilaTheFun/visor/archive/refs/tags/v0.47.1.tar.gz", nil))
        XCTAssertFalse(read("POST", "api.github.com", "/graphql", mutation))
        XCTAssertFalse(read("POST", "api.github.com", "/repos/AttilaTheFun/swift_sql/issues/1/comments", #"{"body":"x"}"#))
        XCTAssertFalse(read("PATCH", "api.github.com", "/repos/AttilaTheFun/swift_sql/pulls/1", #"{"title":"x"}"#))
        XCTAssertFalse(read("PUT", "api.github.com", "/repos/AttilaTheFun/swift_sql/pulls/1/update-branch", "{}"))
        XCTAssertFalse(read("DELETE", "api.github.com", "/repos/AttilaTheFun/swift_sql/issues/comments/1", nil))
        XCTAssertFalse(read("GET", "github.com", "/AttilaTheFun/swift_sql.git/info/refs?service=git-receive-pack", nil))
        XCTAssertFalse(read("POST", "github.com", "/AttilaTheFun/swift_sql.git/git-receive-pack", "0000"))
        XCTAssertFalse(read("POST", "github.com", "/AttilaTheFun/swift_sql.git/info/lfs/objects/batch", #"{"operation":"upload"}"#))
        XCTAssertFalse(read("GET", "github.com", "/AttilaTheFun/swift_sql/settings", nil))
        XCTAssertFalse(read("POST", "uploads.github.com", "/repos/AttilaTheFun/visor/releases/1/assets?name=x", "x"))
        XCTAssertFalse(read("GET", "api.github.com", "/repos/AttilaTheFun/x/../../repos/someone/else", nil), "no plain path")
    }

    func testAPathCantClimbOutOfItsRepository() {
        refused(rest("GET", "/repos/AttilaTheFun/x/../../repos/someone/else"), "no plain path")
        refused(rest("GET", "/repos/AttilaTheFun/x/%2e%2e/y"), "no plain path")
        refused(rest("GET", "/repos/AttilaTheFun/x/a%2Fb"), "no plain path")
        refused(rest("GET", "/repos//AttilaTheFun/x"), "no plain path")
        refused(rest("GET", "/orgs/AttilaTheFun/members"), "outside")
        passes(rest("GET", "/repos/AttilaTheFun/shireworks/contents/docs/my%20file.md?ref=main"))
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
            // 349 and 350 closed; a close is a check of its author now (Logan, 25 Nov 2026), and reopening stays his.
            ("PATCH", "\(repo)/pulls/3", #"{"state":"open"}"#),
            ("PATCH", "\(repo)/issues/3", #"{"state":"open"}"#),
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
        // 384-385, now Logan's alone (14 Nov 2026): a merge, however checked, is refused.
        refused(rest("PUT", "\(repo)/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\",\"commit_title\":\"t\",\"commit_message\":\"m\"}"),
                "merging pull requests is Logan's alone")
        XCTAssertEqual(rest("PUT", "\(repo)/pulls/3/update-branch", "{\"expected_head_sha\":\"\(sha)\"}"),    // 386
                       .check(.updateBranch(repository: "AttilaTheFun/shireworks", number: 3)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/rerun-failed-jobs"),                            // 387
                       .check(.rerun(repository: "AttilaTheFun/shireworks", run: 1, failedOnly: true)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/rerun", "{}"),                                  // 388
                       .check(.rerun(repository: "AttilaTheFun/shireworks", run: 1, failedOnly: false)))
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/cancel"), .check(.cancel(repository: "AttilaTheFun/shireworks", run: 1))) // 389
        // 390 and 371: a dispatch, now of a workflow gate.json lists alone, never on main (NCH's review of #417).
        XCTAssertEqual(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature","inputs":{"kind":"quick"}}"#),
                       .check(.dispatch(repository: "AttilaTheFun/shireworks", workflow: 12, branch: "feature", inputs: ["kind": "quick"])))
        passes(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature","return_run_details":true}"#))
    }

    /// The gate with a workflow an agent may dispatch.
    private func dispatching(_ method: String, _ path: String, _ body: String) -> GateDecision {
        var rules = GateRules.standard
        rules.dispatchableWorkflows = ["ci.yml"]
        return GitHubGate(rules: rules).decide(GateRequest(method: method, host: "api.github.com", target: path, body: Data(body.utf8)))
    }

    /// NCH's review of #417: a workflow is dispatched only where gate.json
    /// lists it (none by default), and never on main or another protected
    /// branch, whatever it lists.
    func testADispatchIsOfAListedWorkflowOffMain() {
        refused(rest("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature"}"#), "dispatchableWorkflows lists none")
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"main"}"#), "never dispatched on main")
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"Master"}"#), "never dispatched on Master")
        refused(dispatching("POST", "\(repo)/actions/workflows/ci.yml/dispatches", #"{"ref":"feature"}"#), "not among the writes")
        refused(dispatching("POST", "\(repo)/dispatches", #"{"event_type":"x"}"#), "not among the writes")
        var rules = GateRules.standard
        rules.dispatchableWorkflows = ["ci.yml"]
        XCTAssertTrue(rules.dispatches(workflowPath: ".github/workflows/ci.yml"))
        XCTAssertFalse(rules.dispatches(workflowPath: ".github/workflows/release.yml"))
        rules.dispatchableWorkflows = [".github/workflows/release.yml"]
        XCTAssertTrue(rules.dispatches(workflowPath: ".github/workflows/release.yml"))
    }

    /// NCH's follow-up to #417: GitHub takes `heads/main` as main, so a
    /// dispatch's ref is a branch's name alone: never `heads/…`, `tags/…` or
    /// `refs/…`, whatever follows.
    func testADispatchsRefIsABranchsNameAlone() {
        for ref in ["heads/main", "Heads/main", "heads/feature", "tags/v1", "TAGS/v1", "refs/heads/feature", "refs/tags/v1", "remotes/origin/x"] {
            refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", "{\"ref\":\"\(ref)\"}"), "")
        }
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"heads/main"}"#), "never heads/… or tags/…")
        XCTAssertEqual(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"agent/heads"}"#),
                       .check(.dispatch(repository: "AttilaTheFun/shireworks", workflow: 12, branch: "agent/heads")))
    }

    /// NCH's follow-up to #417: an own branch's prefix is a folder's, ending
    /// in `/`, or `agent` would cover `agentx`: gate.json with one that
    /// doesn't isn't read, and one set otherwise matches nothing.
    func testOwnBranchPrefixesEndInASlash() throws {
        let json = { (prefixes: String) in
            #"{"repositories":["AttilaTheFun/*"],"protectedBranches":["main"],"protectDefaultBranch":true,"merge":{"methods":["squash"],"passingConclusions":["success"],"codeOwners":true},"rerunEvents":["push"],"dispatch":{"maxInputs":10,"maxValueLength":200},"forcePushToOwnBranches":true,"ownBranchPrefixes":"#
                + prefixes + "}"
        }
        XCTAssertThrowsError(try JSONDecoder().decode(GateRules.self, from: Data(json(#"["agent"]"#).utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(GateRules.self, from: Data(json(#"["agent/", "codex"]"#).utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(GateRules.self, from: Data(json(#"["/"]"#).utf8)))
        let rules = try JSONDecoder().decode(GateRules.self, from: Data(json(#"["agent/", "codex/"]"#).utf8))
        XCTAssertEqual(rules.ownBranchPrefixes, ["agent/", "codex/"])
        XCTAssertTrue(rules.isOwn("codex/fix", defaultBranch: nil))
        XCTAssertFalse(rules.isOwn("agentx", defaultBranch: nil))
        var set = GateRules.standard
        set.ownBranchPrefixes = ["agent"]
        XCTAssertFalse(set.isOwn("agentx", defaultBranch: nil), "a prefix without its / matches nothing")
        XCTAssertFalse(set.isOwn("agent/x", defaultBranch: nil))
    }

    /// NCH's review of #417: an update of a branch that's there may be a
    /// forced one (the pack isn't read), so it goes only to the agent's own
    /// branches, and only while forcePushToOwnBranches says so; a new branch
    /// is pushed anywhere that isn't protected.
    func testAnUpdateThatMayBeForcedGoesToTheAgentsOwnBranchesAlone() {
        let zero = String(repeating: "0", count: 40), old = String(repeating: "b", count: 40)
        func pushed(_ rules: GateRules, _ line: String) -> GateDecision {
            let text = "\(line)\0report-status\n"
            let body = Data((String(format: "%04x", text.utf8.count + 4) + text + "0000PACK").utf8)
            return GitHubGate(rules: rules).decide(GateRequest(method: "POST", host: "github.com",
                                                               target: "/AttilaTheFun/shireworks.git/git-receive-pack", body: body))
        }
        // MultiPass's: every branch that isn't protected is the agent's own.
        XCTAssertEqual(pushed(.standard, "\(old) \(sha) refs/heads/feature"), .check(.push(repository: "AttilaTheFun/shireworks", branches: ["feature"])))
        // Own branches by prefix: an update elsewhere is refused, a new branch isn't.
        var prefixed = GateRules.standard
        prefixed.ownBranchPrefixes = ["agent/"]
        XCTAssertEqual(pushed(prefixed, "\(old) \(sha) refs/heads/agent/fix"),
                       .check(.push(repository: "AttilaTheFun/shireworks", branches: ["agent/fix"])))
        refused(pushed(prefixed, "\(old) \(sha) refs/heads/feature"), "isn't one of the agent's own branches")
        XCTAssertEqual(pushed(prefixed, "\(zero) \(sha) refs/heads/feature"), .check(.push(repository: "AttilaTheFun/shireworks", branches: ["feature"])))
        XCTAssertTrue(prefixed.isOwn("agent/x", defaultBranch: nil))
        XCTAssertFalse(prefixed.isOwn("agent-x", defaultBranch: nil))
        XCTAssertFalse(prefixed.isOwn("agent/x", defaultBranch: "agent/x"), "the default branch is no one's own")
        // No force anywhere: only new branches.
        var none = GateRules.standard
        none.forcePushToOwnBranches = false
        refused(pushed(none, "\(old) \(sha) refs/heads/feature"), "forcePushToOwnBranches")
        XCTAssertEqual(pushed(none, "\(zero) \(sha) refs/heads/feature"), .check(.push(repository: "AttilaTheFun/shireworks", branches: ["feature"])))
    }

    /// NCH's review of #417: logan-shire-agent's token is minted for the
    /// gate's repositories and the permissions its rules need, no more.
    func testTheTokensScopeIsTheGates() {
        XCTAssertNil(GateRules.standard.tokenRepositories(owner: "AttilaTheFun"), "AttilaTheFun/*: every one the installation reaches")
        var listed = GateRules.standard
        listed.repositories = ["AttilaTheFun/visor", "attilathefun/shireworks", "someone/else"]
        XCTAssertEqual(listed.tokenRepositories(owner: "AttilaTheFun"), ["visor", "shireworks"])
        XCTAssertEqual(GateRules.standard.tokenPermissions, ["contents": "write", "pull_requests": "write", "issues": "write",
                                                            "metadata": "read", "checks": "read", "statuses": "read", "actions": "write"])
        var quiet = GateRules.standard
        quiet.rerunEvents = []
        XCTAssertEqual(quiet.tokenPermissions["actions"], "write", "Visor's proposals on main: actions written")
        quiet.mainDispatch = .off
        XCTAssertEqual(quiet.tokenPermissions["actions"], "write", "Visor's verify on a branch: actions written")
        quiet.branchDispatch = .off
        XCTAssertEqual(quiet.tokenPermissions["actions"], "read", "no re-run or dispatch: actions read")
        XCTAssertNil(GateRules.standard.tokenPermissions["workflows"])
    }

    /// gate.json as MultiPass wrote it, without agent-proxy's own fields.
    func testMultiPasssGateJSONStillReads() throws {
        let json = #"{"repositories":["AttilaTheFun/*"],"protectedBranches":["main","master"],"protectDefaultBranch":true,"merge":{"methods":["squash"],"passingConclusions":["success"],"codeOwners":true},"rerunEvents":["push"],"dispatch":{"maxInputs":10,"maxValueLength":200},"forcePushToOwnBranches":true}"#
        let rules = try JSONDecoder().decode(GateRules.self, from: Data(json.utf8))
        XCTAssertEqual(rules.ownBranchPrefixes, [])
        XCTAssertEqual(rules.dispatchableWorkflows, [])
        XCTAssertEqual(rules.mainDispatch, .off, "no dispatch on main, as before it")
        XCTAssertEqual(rules.branchDispatch, .off, "no inputs listed on a branch, as before it")
        // The gate it makes refuses a dispatch on main, as before, and lets a listed one on a branch go to its check.
        var listed = rules
        listed.dispatchableWorkflows = ["ci.yml"]
        let old = GitHubGate(rules: listed)
        let main = old.decide(GateRequest(method: "POST", host: "api.github.com", target: "/repos/AttilaTheFun/visor/actions/workflows/12/dispatches",
                                          body: Data(#"{"ref":"main","inputs":{"run":"verify"}}"#.utf8)))
        refused(main, "never dispatched on main")
        let branch = old.decide(GateRequest(method: "POST", host: "api.github.com", target: "/repos/AttilaTheFun/visor/actions/workflows/12/dispatches",
                                            body: Data(#"{"ref":"feature","inputs":{"anything":"at all"}}"#.utf8)))
        XCTAssertEqual(branch, .check(.dispatch(repository: "AttilaTheFun/visor", workflow: 12, branch: "feature", inputs: ["anything": "at all"])))
    }

    func testReleasesAreDraftsOnly() {
        passes(rest("POST", "\(repo)/releases", #"{"tag_name":"v1.1","target_commitish":"main","name":"1.1","body":"","draft":true}"#))
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1.1"}"#), "a draft only")
        XCTAssertEqual(rest("PATCH", "\(repo)/releases/9", #"{"body":"new"}"#), .check(.releaseEdit(repository: "AttilaTheFun/shireworks", release: 9)))
        refused(rest("PATCH", "\(repo)/releases/9", #"{"body":"new","prerelease":true}"#), "never sends prerelease")
    }

    func testDispatchInputsAreAFewOneLineStrings() {
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature","inputs":"kind=quick"}"#), "JSON object of strings")
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature","inputs":{"kind":"one\ntwo"}}"#), "one line")
        refused(dispatching("POST", "\(repo)/actions/workflows/12/dispatches", #"{"ref":"feature","inputs":{"a b":"x"}}"#), "input's name")
    }

    func testAPullRequestIsBetweenTwoBranchesOfTheRepository() {
        passes(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"feature","base":"main","body":"","draft":false}"#))
        passes(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"AttilaTheFun:feature","base":"main"}"#))
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"someone:feature","base":"main"}"#), "a branch of AttilaTheFun's")
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"main","base":"main"}"#), "the same branch")
        refused(rest("POST", "\(repo)/pulls", #"{"title":"t","head":"feature","base":"main","maintainer_can_modify":true}"#), "never sends")
    }

    // MARK: Logan's alone (14 Nov 2026)

    /// Merging a pull request: REST's merge (any write to it, any body, even
    /// one that names its head), the merge of a branch, and GraphQL's every
    /// way of merging, aliased or not, its input inline or a variable.
    func testMergingIsRefusedEveryWay() {
        let merging = "merging pull requests is Logan's alone, never an agent's"
        refused(rest("PUT", "\(repo)/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"), merging)
        refused(rest("PUT", "\(repo)/pulls/3/merge"), merging)
        refused(rest("POST", "\(repo)/pulls/3/merge", "{}"), merging)
        refused(rest("PUT", "/repos/someone/else/pulls/3/merge", "{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"), merging)
        refused(rest("POST", "\(repo)/merges", #"{"base":"main","head":"feature"}"#), merging)
        // Whether it was merged, a read, still is one.
        passes(rest("GET", "\(repo)/pulls/3/merge"))
        for mutation in ["mergePullRequest", "enablePullRequestAutoMerge", "enqueuePullRequest", "mergeBranch"] {
            refused(graphQL("mutation M($input:X!){\(mutation)(input:$input){clientMutationId}}", variables: #"{"input":{"pullRequestId":"PR_1"}}"#),
                    merging)
            refused(graphQL("mutation { done: \(mutation)(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"), merging)
            refused(graphQL("mutation { \(mutation)(pullRequestId: \"PR_1\") { clientMutationId } }"), merging)
        }
        // Beside an allowed field, the whole mutation.
        refused(graphQL("mutation { addComment(input: {subjectId: \"I\", body: \"x\"}) { clientMutationId } mergePullRequest(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"),
                merging)
    }

    /// Publishing a release: one made other than as a draft, or a draft's
    /// edit that sets `draft: false`.
    func testPublishingAReleaseIsRefused() {
        let publishing = "publishing a release is Logan's alone, never an agent's"
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1","draft":false}"#), publishing)
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1"}"#), publishing)
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1","draft":null}"#), publishing)
        refused(rest("PATCH", "\(repo)/releases/9", #"{"draft":false}"#), publishing)
        refused(rest("PATCH", "\(repo)/releases/9", #"{"body":"notes","draft":false,"make_latest":"true"}"#), publishing)
        // A draft made, and a draft's edit that leaves it one: checked as ever.
        passes(rest("POST", "\(repo)/releases", #"{"tag_name":"v1","draft":true}"#))
        XCTAssertEqual(rest("PATCH", "\(repo)/releases/9", #"{"body":"notes"}"#), .check(.releaseEdit(repository: "AttilaTheFun/shireworks", release: 9)))
    }

    /// Deleting a branch or any other ref: REST's, GraphQL's, and a push's
    /// (a ref updated to the zero commit), of a branch or a tag alike.
    func testDeletingARefIsRefusedEveryWay() {
        let deleting = "deleting a branch or any other ref is Logan's alone, never an agent's"
        refused(rest("DELETE", "\(repo)/git/refs/heads/feature"), deleting)
        refused(rest("DELETE", "\(repo)/git/refs/heads/feature/x"), deleting)
        refused(rest("DELETE", "\(repo)/git/refs/tags/v1.0"), deleting)
        refused(rest("DELETE", "/repos/someone/else/git/refs/heads/x"), deleting)
        refused(graphQL("mutation { deleteRef(input: {refId: \"REF_1\"}) { clientMutationId } }"), deleting)
        refused(graphQL("mutation D($input:DeleteRefInput!){deleteRef(input:$input){clientMutationId}}", variables: #"{"input":{"refId":"REF_1"}}"#),
                deleting)
        let zero = String(repeating: "0", count: 40)
        refused(push(["\(sha) \(zero) refs/heads/feature"]), deleting)
        refused(push(["\(sha) \(zero) refs/tags/v1.0"]), deleting)
        refused(push(["\(sha) \(zero) refs/heads/main"]), deleting)
        refused(push(["\(zero) \(sha) refs/heads/feature", "\(sha) \(zero) refs/heads/other"]), deleting)
        // An update of one's own branch is no delete.
        XCTAssertEqual(push(["\(String(repeating: "b", count: 40)) \(sha) refs/heads/feature"]),
                       .check(.push(repository: "AttilaTheFun/shireworks", branches: ["feature"])))
    }

    /// gate.json can't turn them back on: its format is GateRules', and no
    /// field of it lets a merge, a publish or a delete through.
    func testGateJSONIsTheRulesAndCantLetThemThrough() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(GateRules.standard).write(to: file)
        XCTAssertEqual(try GateRules.load(file.path), .standard)
        var loose = GateRules.standard
        loose.protectedBranches = []
        loose.protectDefaultBranch = false
        loose.merge.codeOwners = false
        let gate = GitHubGate(rules: loose)
        let zero = String(repeating: "0", count: 40)
        if case .refuse = gate.decide(GateRequest(method: "PUT", host: "api.github.com", target: "\(repo)/pulls/3/merge",
                                                  body: Data("{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}".utf8))) {} else { XCTFail("a merge let through") }
        let line = "\(sha) \(zero) refs/heads/feature\0report-status\n"
        let body = Data((String(format: "%04x", line.utf8.count + 4) + line + "0000").utf8)
        if case .refuse = gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks.git/git-receive-pack",
                                                  body: body)) {} else { XCTFail("a delete let through") }
        XCTAssertThrowsError(try GateRules.load("/nonexistent/gate.json"))
    }

    /// The egress log's class of a path: no query, numbers and commits' ids
    /// set aside, at most eight segments.
    func testAPathsClassKeepsNoQueryOrNumbers() {
        XCTAssertEqual(GitHubGate.pathClass("/repos/AttilaTheFun/shireworks/pulls/3/merge?token=x"), "/repos/AttilaTheFun/shireworks/pulls/{n}/merge")
        XCTAssertEqual(GitHubGate.pathClass("/repos/o/r/commits/\(sha)/check-runs"), "/repos/o/r/commits/{sha}/check-runs")
        XCTAssertEqual(GitHubGate.pathClass("/graphql"), "/graphql")
        XCTAssertEqual(GitHubGate.pathClass("/a/b/c/d/e/f/g/h/i/j"), "/a/b/c/d/e/f/g/h/…")
    }

    // MARK: Release proposals on main (NCH's conditions, 26 Nov 2026)

    private func dispatch(_ gate: GitHubGate, in repository: String = "AttilaTheFun/visor", _ body: String) -> GateDecision {
        gate.decide(GateRequest(method: "POST", host: "api.github.com", target: "/repos/\(repository)/actions/workflows/12/dispatches",
                                body: Data(body.utf8)))
    }

    /// The standard rules, with no gate.json: Visor's ci.yml on main with
    /// `run` one of verify, prerelease and release, at most four an hour;
    /// no branch's dispatch.
    func testTheStandardRulesProposeVisorsReleasesOnMain() {
        XCTAssertEqual(GateRules.standard.mainDispatch.perHour, 4)
        XCTAssertEqual(GateRules.standard.mainDispatch.workflows,
                       ["AttilaTheFun/visor:.github/workflows/ci.yml": ["run": ["verify", "prerelease", "release"]]])
        XCTAssertEqual(GateRules.standard.dispatchableWorkflows, [])
        // NCH's review of #557: on a branch, Visor's ci.yml with run verify alone.
        XCTAssertEqual(GateRules.standard.branchDispatch.workflows, ["AttilaTheFun/visor:.github/workflows/ci.yml": ["run": ["verify"]]])
        // To the check, with its inputs, which reads which workflow it is and the default branch.
        XCTAssertEqual(dispatch(gate, #"{"ref":"main","inputs":{"run":"release"}}"#),
                       .check(.dispatch(repository: "AttilaTheFun/visor", workflow: 12, branch: "main", inputs: ["run": "release"])))
        XCTAssertEqual(dispatch(gate, in: "attilathefun/Visor", #"{"ref":"main","inputs":{"run":"verify"}}"#),
                       .check(.dispatch(repository: "attilathefun/Visor", workflow: 12, branch: "main", inputs: ["run": "verify"])))
        // Another repository's main, and its branches: none.
        refused(dispatch(gate, in: "AttilaTheFun/shireworks", #"{"ref":"main","inputs":{"run":"release"}}"#), "names none of its")
        refused(dispatch(gate, in: "AttilaTheFun/shireworks", #"{"ref":"feature","inputs":{"run":"verify"}}"#), "dispatchableWorkflows lists none")
        // Visor's branch, the check's to refuse (it may be a default branch of another name).
        XCTAssertEqual(dispatch(gate, #"{"ref":"feature","inputs":{"run":"verify"}}"#),
                       .check(.dispatch(repository: "AttilaTheFun/visor", workflow: 12, branch: "feature", inputs: ["run": "verify"])))
        // Main by another spelling: never.
        refused(dispatch(gate, #"{"ref":"heads/main","inputs":{"run":"release"}}"#), "never heads/")
        refused(dispatch(gate, #"{"ref":"refs/heads/main","inputs":{"run":"release"}}"#), "names a branch")
        // Inputs within dispatch's limits, as on a branch.
        refused(dispatch(gate, #"{"ref":"main","inputs":{"run":"one\ntwo"}}"#), "one line")
        refused(dispatch(gate, #"{"ref":"main","inputs":"run=release"}"#), "JSON object of strings")
    }

    /// Exact match: a mainDispatch workflow is `owner/name:.github/workflows/<file>`,
    /// never a file's name or a path alone; gate.json with another isn't read.
    func testMainDispatchNamesEachWorkflowExactlyByItsRepository() throws {
        let rules = GateRules.standard.mainDispatch
        XCTAssertEqual(rules.inputs(repository: "AttilaTheFun/visor", path: ".github/workflows/ci.yml"), ["run": ["verify", "prerelease", "release"]])
        XCTAssertEqual(rules.inputs(repository: "attilathefun/VISOR", path: ".github/workflows/ci.yml"), ["run": ["verify", "prerelease", "release"]])
        XCTAssertNil(rules.inputs(repository: "AttilaTheFun/visor", path: ".github/workflows/CI.yml"))
        XCTAssertNil(rules.inputs(repository: "AttilaTheFun/visor", path: ".github/workflows/ci.yaml"))
        XCTAssertNil(rules.inputs(repository: "AttilaTheFun/visor", path: "ci.yml"))
        XCTAssertNil(rules.inputs(repository: "AttilaTheFun/shireworks", path: ".github/workflows/ci.yml"))
        XCTAssertNil(rules.inputs(repository: "AttilaTheFun/visor-fork", path: ".github/workflows/ci.yml"))
        func gateJSON(_ mainDispatch: String) -> Data {
            Data((#"{"repositories":["AttilaTheFun/*"],"protectedBranches":["main"],"protectDefaultBranch":true,"merge":{"methods":["squash"],"passingConclusions":["success"],"codeOwners":true},"rerunEvents":["push"],"dispatch":{"maxInputs":10,"maxValueLength":200},"forcePushToOwnBranches":true,"mainDispatch":"#
                + mainDispatch + "}").utf8)
        }
        for loose in [#"{"workflows":{"ci.yml":{"run":["verify"]}}}"#, #"{"workflows":{".github/workflows/ci.yml":{"run":["verify"]}}}"#,
                      #"{"workflows":{"AttilaTheFun/*:.github/workflows/ci.yml":{"run":["verify"]}}}"#,
                      #"{"workflows":{"AttilaTheFun/visor:ci.yml":{"run":["verify"]}}}"#,
                      #"{"workflows":{"AttilaTheFun/visor:.github/workflows/a/ci.yml":{"run":["verify"]}}}"#,
                      #"{"workflows":{"AttilaTheFun/visor:.github/workflows/ci.yml":{"run":[]}}}"#,
                      #"{"workflows":{"AttilaTheFun/visor:.github/workflows/ci.yml":{"a b":["x"]}}}"#,
                      #"{"perHour":-1,"workflows":{}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(GateRules.self, from: gateJSON(loose)), loose)
        }
        let read = try JSONDecoder().decode(GateRules.self, from: gateJSON(#"{"perHour":2,"workflows":{"AttilaTheFun/visor:.github/workflows/ci.yml":{"run":["verify"]}}}"#))
        XCTAssertEqual(read.mainDispatch, GateRules.MainDispatch(perHour: 2, workflows: ["AttilaTheFun/visor:.github/workflows/ci.yml": ["run": ["verify"]]]))
        // branchDispatch as exactly, and read.
        func branchJSON(_ branchDispatch: String) -> Data {
            Data((#"{"repositories":["AttilaTheFun/*"],"protectedBranches":["main"],"protectDefaultBranch":true,"merge":{"methods":["squash"],"passingConclusions":["success"],"codeOwners":true},"rerunEvents":["push"],"dispatch":{"maxInputs":10,"maxValueLength":200},"forcePushToOwnBranches":true,"branchDispatch":"#
                + branchDispatch + "}").utf8)
        }
        for loose in [#"{"workflows":{"ci.yml":{"run":["verify"]}}}"#, #"{"workflows":{"AttilaTheFun/visor:.github/workflows/ci.yml":{"run":[]}}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(GateRules.self, from: branchJSON(loose)), loose)
        }
        let branchRead = try JSONDecoder().decode(GateRules.self, from: branchJSON(#"{"workflows":{"AttilaTheFun/visor:.github/workflows/ci.yml":{"run":["verify"]}}}"#))
        XCTAssertEqual(branchRead.branchDispatch, .visor)
        XCTAssertEqual(branchRead.mainDispatch, .off)
        // perHour left out: four.
        let unsaid = try JSONDecoder().decode(GateRules.self, from: gateJSON(#"{"workflows":{}}"#))
        XCTAssertEqual(unsaid.mainDispatch.perHour, 4)
        // A branch's list may name one repository's workflow too, exactly.
        var branches = GateRules.standard
        branches.dispatchableWorkflows = ["AttilaTheFun/shireworks:.github/workflows/ci.yml"]
        XCTAssertTrue(branches.dispatches(workflowPath: ".github/workflows/ci.yml", repository: "attilathefun/shireworks"))
        XCTAssertFalse(branches.dispatches(workflowPath: ".github/workflows/ci.yml", repository: "AttilaTheFun/visor"))
        XCTAssertFalse(branches.dispatches(workflowPath: ".github/workflows/ci.yml"))
    }

    /// Logan's alone whatever gate.json says, with every dispatch on main
    /// it could list: publishing, cancelling a release's run (a check:
    /// GateCheckerTests), deleting refs and releases, by REST and GraphQL.
    func testNoGateJSONLetsAPublishACancelOrADeleteThrough() {
        var loose = GateRules.standard
        loose.dispatchableWorkflows = ["ci.yml", "release.yml"]
        loose.mainDispatch = GateRules.MainDispatch(perHour: 1000, workflows: [
            "AttilaTheFun/shireworks:.github/workflows/release.yml": ["publish": ["true"]],
        ])
        loose.protectedBranches = []
        loose.protectDefaultBranch = false
        let gate = GitHubGate(rules: loose)
        func rest(_ method: String, _ path: String, _ body: String? = nil) -> GateDecision {
            gate.decide(GateRequest(method: method, host: "api.github.com", target: path, body: body.map { Data($0.utf8) }))
        }
        func graphQL(_ query: String) -> GateDecision {
            let body = "{\"query\":\(Self.quoted(query))}"
            return gate.decide(GateRequest(method: "POST", host: "api.github.com", target: "/graphql", body: Data(body.utf8)))
        }
        let publishing = "publishing a release is Logan's alone"
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1","draft":false}"#), publishing)
        refused(rest("POST", "\(repo)/releases", #"{"tag_name":"v1"}"#), publishing)
        refused(rest("PATCH", "\(repo)/releases/9", #"{"draft":false}"#), publishing)
        refused(rest("PATCH", "\(repo)/releases/9", #"{"draft":false,"tag_name":"v1"}"#), publishing)
        refused(rest("PATCH", "\(repo)/releases/9", #"{"draft":"false"}"#), "never sends draft")
        refused(rest("PATCH", "\(repo)/releases/9", #"{"make_latest":"true"}"#), "never sends make_latest")
        refused(rest("PUT", "\(repo)/releases/9", #"{"draft":false}"#), "not among the writes")
        refused(rest("POST", "\(repo)/releases/9", #"{"draft":false}"#), "not among the writes")
        for mutation in ["createRelease", "updateRelease", "publishRelease"] {
            refused(graphQL("mutation { \(mutation)(input: {repositoryId: \"R\", tagName: \"v1\"}) { clientMutationId } }"),
                    "not among the mutations")
        }
        // A run's cancel is a check, refused for a release's (GateCheckerTests); force-cancel and deleting a run, never.
        XCTAssertEqual(rest("POST", "\(repo)/actions/runs/1/cancel"), .check(.cancel(repository: "AttilaTheFun/shireworks", run: 1)))
        refused(rest("POST", "\(repo)/actions/runs/1/force-cancel"), "not among the writes")
        refused(rest("DELETE", "\(repo)/actions/runs/1"), "")
        refused(graphQL("mutation { cancelWorkflowRun(input: {workflowRunId: \"W\"}) { clientMutationId } }"), "not among the mutations")
        let deleting = "deleting a branch or any other ref is Logan's alone"
        refused(rest("DELETE", "\(repo)/git/refs/heads/main"), deleting)
        refused(rest("DELETE", "\(repo)/git/refs/tags/v1.0"), deleting)
        refused(graphQL("mutation { deleteRef(input: {refId: \"REF\"}) { clientMutationId } }"), deleting)
        refused(graphQL("mutation { updateRefs(input: {repositoryId: \"R\"}) { clientMutationId } }"), "pushed with git")
        let deletingRelease = "deleting a release, a draft or its asset is Logan's alone"
        refused(rest("DELETE", "\(repo)/releases/9"), deletingRelease)
        refused(rest("DELETE", "\(repo)/releases/assets/3"), deletingRelease)
        refused(rest("DELETE", "/repos/someone/else/releases/9"), deletingRelease)
        refused(graphQL("mutation { deleteRelease(input: {releaseId: \"RE\"}) { clientMutationId } }"), deletingRelease)
        let zero = String(repeating: "0", count: 40)
        refused(push(["\(sha) \(zero) refs/tags/v1.0"], gate: gate), deleting)
        refused(push(["\(sha) \(zero) refs/heads/main"], gate: gate), deleting)
        // A tag is never pushed: no v* tag's release run.
        refused(push(["\(zero) \(sha) refs/tags/v9.9.9"], gate: gate), "never tags")
    }

    // MARK: GraphQL (§3.2)

    func testQueriesPassAndGhsWritesAreCheckedByTheirNodes() {
        passes(graphQL("query PullRequestStatus { repository(owner: \"AttilaTheFun\", name: \"shireworks\") { pullRequests(first: 5) { nodes { number } } } }"))
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
        refused(graphQL("mutation { ok: deleteRef(input: {refId: \"REF_1\"}) { clientMutationId } }"), "deleting a branch or any other ref")
        refused(graphQL("mutation { updateIssue(input: {id: \"I_1\", state: CLOSED}) { clientMutationId } }"), "never sends state")
    }

    func testAMutationIsItsWrittenOutRootFieldsAlone() {
        refused(graphQL("mutation { ...M } fragment M on Mutation { deleteRef(input: {refId: \"x\"}) { clientMutationId } }"), "no fragments")
        refused(graphQL("mutation { reopenIssue(input: {issueId: \"I_1\"}) { clientMutationId } }"), "reopening an issue or a pull request is Logan's alone")
        refused(graphQL("mutation { addComment(input: {subjectId: \"I_1\", body: \"x\"}) { clientMutationId } createRef(input: {repositoryId: \"R\", name: \"refs/heads/x\", oid: \"\(sha)\"}) { clientMutationId } }"),
                "pushed with git")
        refused(graphQL("query A { viewer { login } } mutation B { addComment(input: {subjectId: \"I\", body: \"x\"}) { clientMutationId } }"), "operationName")
        passes(graphQL("query A { viewer { login } } mutation B { addComment(input: {subjectId: \"I\", body: \"x\"}) { clientMutationId } }", operation: "A"))
        refused(graphQL("subscription { x }"), "subscriptions")
        refused(graphQL("mutation { addPullRequestReview(input: {pullRequestId: \"PR\", event: APPROVE}) { clientMutationId } }"), "COMMENT only")
    }

    /// Logan, 25 Nov 2026: agents may close pull requests and issues they
    /// opened themselves. A close, by REST or as gh sends it by GraphQL, is
    /// a check of its author (GateChecker+Close); reopening, an agent's own
    /// included, is refused.
    func testAClosesAuthorIsCheckedAndReopeningIsRefused() {
        let named = "AttilaTheFun/shireworks"
        XCTAssertEqual(rest("PATCH", "\(repo)/pulls/3", #"{"state":"closed"}"#), .check(.close(repository: named, number: 3)))
        XCTAssertEqual(rest("PATCH", "\(repo)/issues/4", #"{"state":"closed"}"#), .check(.close(repository: named, number: 4)))
        XCTAssertEqual(rest("PATCH", "\(repo)/issues/4", #"{"state":"closed","state_reason":"not_planned"}"#),
                       .check(.close(repository: named, number: 4)))
        XCTAssertEqual(rest("PATCH", "\(repo)/issues/4", #"{"state":"closed","title":"t"}"#), .check(.close(repository: named, number: 4)),
                       "an edit the gate allows, with the close")
        refused(rest("PATCH", "\(repo)/pulls/3", #"{"state":"open"}"#), "reopening an issue or a pull request is Logan's alone")
        refused(rest("PATCH", "\(repo)/issues/4", #"{"state":"open"}"#), "reopening an issue or a pull request is Logan's alone")
        refused(rest("PATCH", "\(repo)/issues/4", #"{"state_reason":"reopened"}"#), "goes with state: closed")
        refused(rest("PATCH", "\(repo)/issues/4", #"{"state":"closed","state_reason":"reopened"}"#), "state_reason is completed or not_planned")
        refused(rest("PATCH", "\(repo)/issues/4", #"{"state":"locked"}"#), "isn't a state")
        refused(rest("PATCH", "\(repo)/pulls/3", #"{"state":"closed","base":"main"}"#), "never sends base")
        refused(rest("PATCH", "/repos/someone/else/pulls/3", #"{"state":"closed"}"#), "not among the repositories")
        // As gh pr close and gh issue close send them.
        XCTAssertEqual(graphQL("mutation PullRequestClose($input:ClosePullRequestInput!){closePullRequest(input: $input){pullRequest{id}}}",
                               variables: #"{"input":{"pullRequestId":"PR_1"}}"#),
                       .check(.graphQLClose(id: "PR_1", kind: "PullRequest")))
        XCTAssertEqual(graphQL("mutation IssueClose($input:CloseIssueInput!){closeIssue(input: $input){issue{id}}}",
                               variables: #"{"input":{"issueId":"I_1","stateReason":"NOT_PLANNED"}}"#),
                       .check(.graphQLClose(id: "I_1", kind: "Issue")))
        XCTAssertEqual(graphQL("mutation { closeIssue(input: {issueId: \"I_1\", stateReason: COMPLETED}) { clientMutationId } }"),
                       .check(.graphQLClose(id: "I_1", kind: "Issue")))
        refused(graphQL("mutation { closeIssue(input: {issueId: \"I_1\", stateReason: REOPENED}) { clientMutationId } }"), "stateReason")
        refused(graphQL("mutation { closeIssue(input: {issueId: \"I_1\", duplicateIssueId: \"I_2\"}) { clientMutationId } }"),
                "never sends duplicateIssueId")
        refused(graphQL("mutation { closePullRequest(input: {}) { clientMutationId } }"), "names its pullRequestId")
        refused(graphQL("mutation { closeIssue(input: {issueId: \"I_1\"}) { clientMutationId } addComment(input: {subjectId: \"I_1\", body: \"x\"}) { clientMutationId } }"),
                "a mutation of its own")
        refused(graphQL("mutation { reopenIssue(input: {issueId: \"I_1\"}) { clientMutationId } }"), "reopening")
        refused(graphQL("mutation { reopenPullRequest(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"),
                "reopening an issue or a pull request is Logan's alone, an agent's own included (reopenPullRequest)")
    }

    func testGhPrMergeAndAutoMergeAreRefused() {
        refused(graphQL("mutation PullRequestMerge($input:MergePullRequestInput!){mergePullRequest(input:$input){clientMutationId}}",
                        variables: #"{"input":{"pullRequestId":"PR_1","mergeMethod":"SQUASH","commitHeadline":"t"}}"#),
                "merging pull requests is Logan's alone, never an agent's (mergePullRequest)")
        refused(graphQL("mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"), "merging pull requests")
        refused(graphQL("mutation { disablePullRequestAutoMerge(input: {pullRequestId: \"PR_1\"}) { clientMutationId } }"), "no auto-merge")
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

    private func push(_ lines: [String], repository: String = "AttilaTheFun/shireworks", gate: GitHubGate? = nil) -> GateDecision {
        let body = Data(pushList(lines) + Array("PACK".utf8))
        return (gate ?? self.gate).decide(GateRequest(method: "POST", host: "github.com", target: "/\(repository).git/git-receive-pack", body: body))
    }

    func testFetchesPassAndAPushIsCheckedByItsCommands() {
        passes(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/AttilaTheFun/shireworks.git/info/refs?service=git-upload-pack")))
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks/git-upload-pack")))
        XCTAssertEqual(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/someone/else.git/info/refs?service=git-upload-pack")),
                       .anonymous(repository: "someone/else"), "outside the allowed ones: anonymously")
        refused(gate.decide(GateRequest(method: "GET", host: "github.com", target: "/login")), "only a repository's git")
        let zero = String(repeating: "0", count: 40)
        let other = String(repeating: "b", count: 40)
        XCTAssertEqual(push(["\(zero) \(sha) refs/heads/feature/x"]), .check(.push(repository: "AttilaTheFun/shireworks", branches: ["feature/x"])))
        // A forced update of one's own branch: Logan's choice ([G3f]).
        XCTAssertEqual(push(["\(other) \(sha) refs/heads/fix"]), .check(.push(repository: "AttilaTheFun/shireworks", branches: ["fix"])))
        refused(push(["\(other) \(sha) refs/heads/main"]), "never pushed")
        refused(push(["\(other) \(sha) refs/heads/Master"]), "never pushed")
        refused(push(["\(zero) \(sha) refs/tags/v1.0"]), "never tags")
        refused(push(["\(zero) \(sha) refs/heads/feature", "\(other) \(sha) refs/heads/main"]), "never pushed")
        refused(push(["\(sha) \(zero) refs/heads/feature"]), "deleting a branch or any other ref")
        refused(push(["\(zero) \(sha) refs/heads/a..b"]), "not a branch name")
        refused(push(["\(zero) \(sha) refs/heads/x.lock"]), "not a branch name")
        refused(push(["\(zero) \(sha) refs/heads/feature"], repository: "someone/else"), "not among")
        // git's probe, a flush alone.
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks.git/git-receive-pack", body: Data("0000".utf8))))
        refused(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks.git/git-receive-pack",
                                        body: Data(pushList(["push-cert"])))), "signed pushes")
    }

    func testBranchNamesAreGits() {
        for good in ["feature/x", "fix", "release-0.47", "a.b"] { XCTAssertTrue(GitRefName.isBranch(good), good) }
        for bad in ["a..b", "x.lock", "a b", "x:y", "HEAD", "", "a/", ".hidden", "a/.b", "x@{y", "a\\b", "~x"] {
            XCTAssertFalse(GitRefName.isBranch(bad), bad)
        }
    }

    func testUploadsAndLFSWrites() {
        refused(gate.decide(GateRequest(method: "POST", host: "uploads.github.com", target: "/repos/AttilaTheFun/shireworks/releases/1/assets?name=x")))
        passes(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks.git/info/lfs/objects/batch",
                                       body: Data(#"{"operation":"download","objects":[]}"#.utf8))))
        refused(gate.decide(GateRequest(method: "POST", host: "github.com", target: "/AttilaTheFun/shireworks.git/info/lfs/objects/batch",
                                        body: Data(#"{"operation":"upload","objects":[]}"#.utf8))), "uploads")
    }
}
