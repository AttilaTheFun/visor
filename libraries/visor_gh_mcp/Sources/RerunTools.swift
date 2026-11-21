import Foundation

/// Running a workflow run's jobs again, and cancelling a run. Logan
/// (2026-10-31): agents may re-run and cancel CI as long as it is
/// non-destructive and gh_mcp controls what they can do; they still need
/// green CI to merge, whether from the first run or a re-run (pr_merge
/// requires every check run on the head completed and passed, so a re-run
/// in progress holds a merge until it passes).
///
/// A re-run is only of a completed pull_request, push or workflow_dispatch
/// run whose commit is still its branch's head: an old commit's run is
/// never brought back, and release and schedule runs are never run again. A
/// cancel is of any run still going, except a release's (its publishing
/// must finish). A dispatch (Logan, 2026-11-06: agents dispatch and re-run
/// CI themselves) runs a workflow that declares workflow_dispatch on a
/// branch of the same repository, with short one-line inputs, and names the
/// run it made and its commit. No force-cancel, no deleting runs or logs.
enum RerunTools {
    /// The events whose runs may be run again.
    static let rerunnableEvents = ["pull_request", "push", "workflow_dispatch"]

    /// The run, with the commit it ran on.
    static func run(_ repo: RepoName, _ runID: Int, _ context: ToolContext) async throws -> JSON {
        let run = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/runs/\(runID)")
        guard Policy.isSHA(run["head_sha"]?.stringValue) else { throw ToolError.failed("GitHub gave run \(runID) no head SHA") }
        return run
    }

    static func describe(_ run: JSON, _ runID: Int) -> String {
        let workflow = run["name"]?.stringValue ?? "workflow"
        let branch = run["head_branch"]?.stringValue.map { " on \($0)" } ?? ""
        return "run \(runID) (\(workflow)\(branch))"
    }

    static func rerun(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let runID = arguments.int("run_id")!
        let failedOnly = arguments.bool("failed_only") ?? true
        let run = try await run(repo, runID, context)
        let name = describe(run, runID)

        // Completed: a run still going is cancelled first, or left to finish.
        let status = run["status"]?.stringValue ?? "unknown"
        guard status == "completed" else { throw ToolError.refused("\(name) is \(status), not completed: only a finished run is run again") }

        // Only a pull request's or a push's run: never a release's, a
        // dispatch's or a schedule's.
        let event = run["event"]?.stringValue ?? "unknown"
        guard rerunnableEvents.contains(event) else {
            throw ToolError.refused("\(name) is a \(event) run: only pull_request, push and workflow_dispatch runs are run again")
        }

        // From a branch of this repository, never a fork's.
        let headRepository = run["head_repository"]?["full_name"]?.stringValue
        guard let headRepository, headRepository.caseInsensitiveCompare(repo.description) == .orderedSame else {
            throw ToolError.refused("\(name)'s commit is \(headRepository.map { "in \($0)" } ?? "in a deleted repository"), not a branch of \(repo)")
        }
        guard let branch = run["head_branch"]?.stringValue, Refs.isValid(branch) else {
            throw ToolError.failed("GitHub gave \(name) no branch")
        }

        // Its commit still the head: of an open pull request from the branch
        // for a pull_request run, of the branch for a push.
        let sha = run["head_sha"]!.stringValue!
        let current: String
        if event == "pull_request" {
            let pulls = try await context.github.json(repo, "GET", "/repos/\(repo)/pulls",
                                                      query: ["head": "\(repo.owner):\(branch)", "state": "open", "per_page": "10"])
            let heads = (pulls.arrayValue ?? []).compactMap { $0["head"]?["sha"]?.stringValue }
            guard let head = heads.first(where: { $0 == sha }) ?? heads.first else {
                throw ToolError.refused("\(name): no pull request from \(branch) is open, so its runs aren't run again")
            }
            current = head
        } else {
            let path = "/repos/\(repo)/git/ref/heads/" + branch.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
            let response = try await context.github.send(repo, "GET", path)
            if response.status == 404 { throw ToolError.refused("\(name): \(branch) is no longer a branch of \(repo)") }
            guard response.isSuccess, let ref = try? JSON.parse(response.body), let tip = ref["object"]?["sha"]?.stringValue else {
                throw ToolError.failed(GitHub.describe(response, method: "GET", path: path))
            }
            current = tip
        }
        guard current == sha else {
            throw ToolError.refused("\(name) is of \(sha.prefix(12)), but \(branch)'s head is now \(current.prefix(12)): only the head's runs are run again")
        }

        // rerun-failed-jobs runs the failed and cancelled jobs (and those
        // that depend on them); a run where nothing failed has none.
        let conclusion = run["conclusion"]?.stringValue ?? "none"
        if failedOnly && ["success", "skipped", "neutral"].contains(conclusion) {
            throw ToolError.refused("\(name) concluded \(conclusion): no job failed (failed_only: false runs every job again)")
        }
        let path = "/repos/\(repo)/actions/runs/\(runID)/" + (failedOnly ? "rerun-failed-jobs" : "rerun")
        let response = try await context.github.send(repo, "POST", path)
        guard response.isSuccess else { throw actionsFailure(response, method: "POST", path: path) }
        let url = run["html_url"]?.stringValue ?? "https://github.com/\(repo)/actions/runs/\(runID)"
        return """
            Running \(failedOnly ? "the failed jobs of" : "every job of") \(name) again, on \(sha.prefix(12)): \(url). \
            Its checks run again; a merge waits for them to pass.
            """
    }

    /// A workflow run on a branch, by its workflow_dispatch trigger.
    static func dispatch(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let workflow = arguments.string("workflow")!
        guard workflow.range(of: #"^([A-Za-z0-9._-]+\.ya?ml|[0-9]+)$"#, options: .regularExpression) != nil else {
            throw ToolError.invalid("workflow is a file name in .github/workflows (ci.yml) or a workflow's id: \(workflow)")
        }
        let ref = arguments.string("ref")!
        guard Refs.isValid(ref), !ref.hasPrefix("refs/") else { throw ToolError.invalid("ref is a branch's name: \(ref)") }
        let inputs = try dispatchInputs(arguments.string("inputs"))

        // The workflow, as GitHub knows it (active, its id for the dispatch).
        let found = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/workflows/\(encodeSegment(workflow))")
        guard let id = found["id"]?.intValue else { throw ToolError.failed("GitHub gave workflow \(workflow) no id") }
        let title = found["name"]?.stringValue ?? workflow
        guard found["state"]?.stringValue == "active" else {
            throw ToolError.refused("\(title) is \(found["state"]?.stringValue ?? "not active"): it isn't dispatched")
        }
        // A branch of this repository, at the commit the run will be of.
        let path = "/repos/\(repo)/git/ref/heads/" + ref.split(separator: "/").map { encodeSegment(String($0)) }.joined(separator: "/")
        let response = try await context.github.send(repo, "GET", path)
        if response.status == 404 { throw ToolError.refused("\(ref) is not a branch of \(repo)") }
        guard response.isSuccess, let refJSON = try? JSON.parse(response.body), let sha = refJSON["object"]?["sha"]?.stringValue,
              Policy.isSHA(sha) else {
            throw ToolError.failed(GitHub.describe(response, method: "GET", path: path))
        }
        let asked = Date()
        let dispatches = "/repos/\(repo)/actions/workflows/\(id)/dispatches"
        var body: [String: JSON] = ["ref": .string(ref)]
        if !inputs.isEmpty { body["inputs"] = .object(inputs.mapValues { .string($0) }) }
        let sent = try await context.github.send(repo, "POST", dispatches, body: .object(body))
        guard sent.isSuccess else {
            if sent.status == 422 { throw ToolError.refused(GitHub.describe(sent, method: "POST", path: dispatches) + " (does \(workflow) on \(ref) declare workflow_dispatch, with these inputs?)") }
            throw actionsFailure(sent, method: "POST", path: dispatches)
        }
        // GitHub answers 204 with no run: the run is found by its workflow, branch, event and commit.
        let summary = "\(title) dispatched on \(ref) at \(sha.prefix(12))" + (inputs.isEmpty ? "" : ", inputs \(inputs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(2))
            let runs = try await context.github.json(repo, "GET", "/repos/\(repo)/actions/workflows/\(id)/runs",
                                                      query: ["event": "workflow_dispatch", "branch": ref, "per_page": "5"])
            let made = (runs["workflow_runs"]?.arrayValue ?? []).first { run in
                run["head_sha"]?.stringValue == sha
                    && (run["created_at"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast) >= asked.addingTimeInterval(-10)
            }
            if let made, let runID = made["id"]?.intValue {
                return "\(summary): run \(runID), \(made["html_url"]?.stringValue ?? "https://github.com/\(repo)/actions/runs/\(runID)")."
            }
        }
        return "\(summary). GitHub hasn't listed its run yet: runs (event workflow_dispatch, branch \(ref)) shows it."
    }

    /// A dispatch's inputs: a JSON object of at most 10 one-line strings.
    static func dispatchInputs(_ given: String?) throws -> [String: String] {
        guard let given, !given.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
        guard let parsed = try? JSON.parse(Data(given.utf8)), let object = parsed.objectValue else {
            throw ToolError.invalid(#"inputs is a JSON object of strings, like {"kind": "quick"}"#)
        }
        guard object.count <= 10 else { throw ToolError.invalid("at most 10 inputs") }
        var inputs: [String: String] = [:]
        for (key, value) in object {
            guard key.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw ToolError.invalid("an input's name is letters, digits, _ and -: \(key)") }
            guard let text = value.stringValue, text.count <= 200, !text.contains(where: \.isNewline) else {
                throw ToolError.invalid("input \(key) is one line of at most 200 characters")
            }
            inputs[key] = text
        }
        return inputs
    }

    static func cancel(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let repo = try context.repo(arguments)
        let runID = arguments.int("run_id")!
        let run = try await run(repo, runID, context)
        let name = describe(run, runID)
        let status = run["status"]?.stringValue ?? "unknown"
        guard status != "completed" else {
            throw ToolError.refused("\(name) is already completed (\(run["conclusion"]?.stringValue ?? "no conclusion")): nothing to cancel")
        }
        let event = run["event"]?.stringValue ?? "unknown"
        guard event != "release" else { throw ToolError.refused("\(name) is a release's run: its publishing must finish") }
        let path = "/repos/\(repo)/actions/runs/\(runID)/cancel"
        let response = try await context.github.send(repo, "POST", path)
        guard response.isSuccess else {
            // 409: it finished, or can't be cancelled any more.
            if response.status == 409 { throw ToolError.refused(GitHub.describe(response, method: "POST", path: path)) }
            throw actionsFailure(response, method: "POST", path: path)
        }
        return "Asked GitHub to cancel \(name), which was \(status); GitHub cancels asynchronously (run_view shows when it has stopped)."
    }

    /// GitHub's refusal, with what to grant when it is the app's permission.
    static func actionsFailure(_ response: GitHubResponse, method: String, path: String) -> ToolError {
        var text = GitHub.describe(response, method: method, path: path)
        if response.status == 403 { text += " (the GitHub App needs Actions: Read and write)" }
        return .failed(text)
    }
}
