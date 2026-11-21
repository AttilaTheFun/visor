// run_rerun, run_cancel and run_dispatch, as they came.

import Foundation
import Testing
@testable import VisorGHMCP

// MARK: Re-runs and cancels

let oldSHA = String(repeating: "b", count: 40)

func workflowRun(_ changes: [String: JSON] = [:]) -> JSON {
    var run: [String: JSON] = [
        "id": 77, "name": "CI", "event": "pull_request", "status": "completed", "conclusion": "failure",
        "head_branch": "feature", "head_sha": .string(headSHA), "head_repository": ["full_name": "AttilaTheFun/oss"],
        "html_url": "https://github.com/AttilaTheFun/oss/actions/runs/77",
    ]
    for (key, value) in changes { run[key] = value }
    return .object(run)
}

/// A fake GitHub where run 77 of AttilaTheFun/oss is `run`, pull request 50
/// from feature is open at `pullHead`, and feature's tip is `branchTip`.
func runTransport(_ run: JSON = workflowRun(), pullHead: String = headSHA, branchTip: String = headSHA) -> FakeTransport {
    FakeTransport([
        "GET /repos/AttilaTheFun/oss/actions/runs/77": (200, run),
        "GET /repos/AttilaTheFun/oss/pulls": (200, [["number": 50, "head": ["ref": "feature", "sha": .string(pullHead)]]]),
        "GET /repos/AttilaTheFun/oss/git/ref/heads/feature": (200, ["ref": "refs/heads/feature", "object": ["sha": .string(branchTip)]]),
        "POST /repos/AttilaTheFun/oss/actions/runs/77/rerun-failed-jobs": (201, [:]),
        "POST /repos/AttilaTheFun/oss/actions/runs/77/rerun": (201, [:]),
        "POST /repos/AttilaTheFun/oss/actions/runs/77/cancel": (202, [:]),
    ])
}

func actionWrites(_ transport: FakeTransport) -> [GitHubRequest] {
    transport.requests.filter { $0.method == "POST" }
}

@Test func rerunRunsAFailedPullRequestRunAtItsHead() async {
    let transport = runTransport()
    let server = makeServer(transport: transport)
    let answer = await call(server, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77])
    #expect(!answer.isError, "\(answer.text)")
    #expect(answer.text.contains("https://github.com/AttilaTheFun/oss/actions/runs/77") && answer.text.contains("a merge waits for them to pass"))
    #expect(actionWrites(transport).map(\.path) == ["/repos/AttilaTheFun/oss/actions/runs/77/rerun-failed-jobs"])
    #expect(actionWrites(transport).first?.body == nil)
    let lookup = transport.requests.first { $0.path == "/repos/AttilaTheFun/oss/pulls" }
    #expect(lookup?.query["head"] == "AttilaTheFun:feature" && lookup?.query["state"] == "open")
}

@Test func rerunFailedOnlyPicksThePath() async {
    let every = runTransport(workflowRun(["conclusion": "success"]))
    let server = makeServer(transport: every)
    let answer = await call(server, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77, "failed_only": false])
    #expect(!answer.isError, "\(answer.text)")
    #expect(actionWrites(every).map(\.path) == ["/repos/AttilaTheFun/oss/actions/runs/77/rerun"])

    let failed = runTransport()
    let other = makeServer(transport: failed)
    #expect(!(await call(other, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77, "failed_only": true]).isError))
    #expect(actionWrites(failed).map(\.path) == ["/repos/AttilaTheFun/oss/actions/runs/77/rerun-failed-jobs"])
}

@Test func rerunRunsAPushRunAtItsBranchTip() async {
    let transport = runTransport(workflowRun(["event": "push", "head_branch": "feature"]))
    let server = makeServer(transport: transport)
    let answer = await call(server, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77])
    #expect(!answer.isError, "\(answer.text)")
    #expect(transport.requests.contains { $0.path == "/repos/AttilaTheFun/oss/git/ref/heads/feature" })
    #expect(actionWrites(transport).count == 1)
}

@Test func rerunRefusedUnlessEveryGuardHolds() async {
    let cases: [(String, FakeTransport, [String: JSON], String)] = [
        ("not the pull request's head", runTransport(pullHead: oldSHA), [:], "only the head's runs"),
        ("not the branch's tip", runTransport(workflowRun(["event": "push"]), branchTip: oldSHA), [:], "only the head's runs"),
        ("running", runTransport(workflowRun(["status": "in_progress", "conclusion": .null])), [:], "is in_progress, not completed"),
        ("queued", runTransport(workflowRun(["status": "queued", "conclusion": .null])), [:], "is queued, not completed"),
        ("release", runTransport(workflowRun(["event": "release"])), [:], "is a release run"),
        ("schedule", runTransport(workflowRun(["event": "schedule"])), [:], "is a schedule run"),
        ("fork", runTransport(workflowRun(["head_repository": ["full_name": "someone/oss"]])), [:], "in someone/oss"),
        ("no open pull request", FakeTransport([
            "GET /repos/AttilaTheFun/oss/actions/runs/77": (200, workflowRun()),
            "GET /repos/AttilaTheFun/oss/pulls": (200, []),
        ]), [:], "no pull request from feature is open"),
        ("branch gone", FakeTransport([
            "GET /repos/AttilaTheFun/oss/actions/runs/77": (200, workflowRun(["event": "push"])),
        ]), [:], "no longer a branch"),
        ("nothing failed", runTransport(workflowRun(["conclusion": "success"])), [:], "no job failed"),
    ]
    for (name, transport, extra, reason) in cases {
        let server = makeServer(transport: transport)
        var arguments: [String: JSON] = ["repo": "AttilaTheFun/oss", "run_id": 77]
        for (key, value) in extra { arguments[key] = value }
        let answer = await call(server, "run_rerun", .object(arguments))
        #expect(answer.isError && answer.text.hasPrefix("Refused") && answer.text.contains(reason), "\(name): \(answer.text)")
        #expect(actionWrites(transport).isEmpty, "\(name) sent a re-run")
    }
}

@Test func cancelCancelsARunStillGoing() async {
    for status in ["in_progress", "queued"] {
        let transport = runTransport(workflowRun(["status": .string(status), "conclusion": .null]))
        let server = makeServer(transport: transport)
        let answer = await call(server, "run_cancel", ["repo": "AttilaTheFun/oss", "run_id": 77])
        #expect(!answer.isError && answer.text.contains("asynchronously"), "\(status): \(answer.text)")
        #expect(actionWrites(transport).map(\.path) == ["/repos/AttilaTheFun/oss/actions/runs/77/cancel"])
        #expect(actionWrites(transport).first?.body == nil)
    }
}

@Test func cancelRefusedForAReleaseOrACompletedRun() async {
    let cases: [(String, JSON, String)] = [
        ("release", workflowRun(["event": "release", "status": "in_progress", "conclusion": .null]), "its publishing must finish"),
        ("completed", workflowRun(), "already completed"),
    ]
    for (name, run, reason) in cases {
        let transport = runTransport(run)
        let server = makeServer(transport: transport)
        let answer = await call(server, "run_cancel", ["repo": "AttilaTheFun/oss", "run_id": 77])
        #expect(answer.isError && answer.text.hasPrefix("Refused") && answer.text.contains(reason), "\(name): \(answer.text)")
        #expect(actionWrites(transport).isEmpty, "\(name) sent a cancel")
    }
}

@Test func rerunRunsADispatchedRunAtItsBranchTip() async {
    let transport = runTransport(workflowRun(["event": "workflow_dispatch", "head_branch": "feature"]))
    let server = makeServer(transport: transport)
    let answer = await call(server, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77])
    #expect(!answer.isError, "\(answer.text)")
    #expect(transport.requests.contains { $0.path == "/repos/AttilaTheFun/oss/git/ref/heads/feature" })
    #expect(actionWrites(transport).map(\.path) == ["/repos/AttilaTheFun/oss/actions/runs/77/rerun-failed-jobs"])
    // Not when the branch has moved on.
    let moved = runTransport(workflowRun(["event": "workflow_dispatch"]), branchTip: oldSHA)
    let other = makeServer(transport: moved)
    let refusedAnswer = await call(other, "run_rerun", ["repo": "AttilaTheFun/oss", "run_id": 77])
    #expect(refusedAnswer.isError && refusedAnswer.text.contains("only the head's runs"))
    #expect(actionWrites(moved).isEmpty)
}

@Test func dispatchRunsAWorkflowOnABranchAndNamesItsRun() async {
    let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
    let transport = FakeTransport([
        "GET /repos/AttilaTheFun/oss/actions/workflows/ci.yml": (200, ["id": 12, "name": "CI", "state": "active"]),
        "GET /repos/AttilaTheFun/oss/git/ref/heads/feature": (200, ["ref": "refs/heads/feature", "object": ["sha": .string(headSHA)]]),
        "POST /repos/AttilaTheFun/oss/actions/workflows/12/dispatches": (204, [:]),
        "GET /repos/AttilaTheFun/oss/actions/workflows/12/runs": (200, ["workflow_runs": [
            ["id": 901, "head_sha": .string(headSHA), "created_at": .string(now), "html_url": "https://github.com/AttilaTheFun/oss/actions/runs/901"],
        ]]),
    ])
    let server = makeServer(transport: transport)
    let answer = await call(server, "run_dispatch", ["repo": "AttilaTheFun/oss", "workflow": "ci.yml", "ref": "feature",
                                                              "inputs": #"{"kind": "quick"}"#])
    #expect(!answer.isError, "\(answer.text)")
    #expect(answer.text.contains("run 901") && answer.text.contains(String(headSHA.prefix(12))) && answer.text.contains("kind=quick"))
    let sent = actionWrites(transport).first
    #expect(sent?.path == "/repos/AttilaTheFun/oss/actions/workflows/12/dispatches")
    #expect(sent?.body?["ref"] == "feature" && sent?.body?["inputs"]?["kind"] == "quick")
}

@Test func dispatchRefusesWhatItShouldNot() async {
    let inactive = FakeTransport(["GET /repos/AttilaTheFun/oss/actions/workflows/ci.yml": (200, ["id": 12, "name": "CI", "state": "disabled_manually"])])
    let cases: [(String, FakeTransport, [String: JSON], String)] = [
        ("a tag", FakeTransport([:]), ["workflow": "ci.yml", "ref": "refs/tags/v1"], "Invalid"),
        ("a path", FakeTransport([:]), ["workflow": "../x.yml", "ref": "main"], "Invalid"),
        ("inputs not JSON", FakeTransport([:]), ["workflow": "ci.yml", "ref": "main", "inputs": "kind=quick"], "Invalid"),
        ("an input of two lines", FakeTransport([:]), ["workflow": "ci.yml", "ref": "main", "inputs": #"{"kind": "a\nb"}"#], "Invalid"),
        ("an inactive workflow", inactive, ["workflow": "ci.yml", "ref": "main"], "Refused"),
        ("no such branch", FakeTransport(["GET /repos/AttilaTheFun/oss/actions/workflows/ci.yml": (200, ["id": 12, "name": "CI", "state": "active"])]),
         ["workflow": "ci.yml", "ref": "gone"], "Refused"),
    ]
    for (name, transport, extra, prefix) in cases {
        let server = makeServer(transport: transport)
        var arguments: [String: JSON] = ["repo": "AttilaTheFun/oss"]
        for (key, value) in extra { arguments[key] = value }
        let answer = await call(server, "run_dispatch", .object(arguments))
        #expect(answer.isError && answer.text.hasPrefix(prefix), "\(name): \(answer.text)")
        #expect(actionWrites(transport).isEmpty, "\(name) dispatched")
    }
}
