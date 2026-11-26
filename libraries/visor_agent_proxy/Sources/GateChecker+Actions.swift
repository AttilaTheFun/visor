import Foundation

// The Actions checks (docs/github-gate-rules.md, §2.8): a re-run only of a
// finished push, pull_request or workflow_dispatch run at its branch's head
// ([RR1]-[RR8]); a cancel only of a run still going, never a release's
// ([C1], [C2]), nor a dispatch's on the default branch; a dispatch only of
// an active workflow on a branch that is there ([D5], [D6]), or on the
// default branch as gate.json's mainDispatch says (NCH's conditions for
// agents' release proposals, 26 Nov 2026).

extension GateChecker {
    /// A run, and its name as messages give it.
    private func run(_ repository: String, _ id: Int) async -> Result<(GitHubAnswer, String), CheckOutcome> {
        let answer = await github.get("/repos/\(repository)/actions/runs/\(id)")
        guard answer.ok else { return .failure(.fail("GitHub didn't give run \(id) of \(repository) (\(answer.status))")) }
        guard let sha = answer["head_sha"]?.string, GitRefName.isSHA(sha) else { return .failure(.fail("GitHub gave run \(id) no head SHA")) }
        let workflow = answer["name"]?.string ?? "a workflow"
        let branch = answer["head_branch"]?.string.map { " on \($0)" } ?? ""
        return .success((answer, "run \(id) (\(workflow)\(branch))"))
    }

    func rerun(_ repository: String, _ id: Int, failedOnly: Bool) async -> CheckOutcome {
        let (answer, name): (GitHubAnswer, String)
        switch await run(repository, id) {
        case .failure(let outcome): return outcome
        case .success(let found): (answer, name) = found
        }
        let status = answer["status"]?.string ?? "unknown"
        guard status == "completed" else { return .refuse("\(name) is \(status), not completed: only a finished run is run again") }
        let event = answer["event"]?.string ?? "unknown"
        guard rules.rerunEvents.contains(event) else {
            return .refuse("\(name) is a \(event) run: only \(rules.rerunEvents.joined(separator: ", ")) runs are run again")
        }
        guard let headRepository = answer["head_repository", "full_name"]?.string else {
            return .refuse("\(name)'s commit is in a deleted repository, not a branch of \(repository)")
        }
        guard headRepository.lowercased() == repository.lowercased() else {
            return .refuse("\(name)'s commit is in \(headRepository), not a branch of \(repository)")
        }
        guard let branch = answer["head_branch"]?.string, GitRefName.isBranch(branch) else { return .fail("GitHub gave \(name) no branch") }
        let sha = answer["head_sha"]?.string ?? ""
        let current: String
        if event == "pull_request" {
            let owner = repository.split(separator: "/").first.map(String.init) ?? ""
            let pulls = await github.get("/repos/\(repository)/pulls?head=\(Self.encoded(owner)):\(Self.encoded(branch))&state=open&per_page=10")
            guard pulls.ok else { return .fail("GitHub didn't give \(branch)'s pull requests (\(pulls.status))") }
            let heads = pulls.json?.array?.compactMap { $0.object?["head"]?.object?["sha"]?.string } ?? []
            guard let first = heads.first else { return .refuse("\(name): no pull request from \(branch) is open, so its runs aren't run again") }
            current = heads.first { $0 == sha } ?? first
        } else {
            switch await branchHead(repository, branch) {
            case .failure(let outcome):
                if case .refuse = outcome { return .refuse("\(name): \(branch) is no longer a branch of \(repository)") }
                return outcome
            case .success(let head): current = head
            }
        }
        guard current == sha else {
            return .refuse("\(name) is of \(Self.short(sha)), but \(branch)'s head is now \(Self.short(current)): only the head's runs are run again")
        }
        if failedOnly, let conclusion = answer["conclusion"]?.string, rules.merge.passingConclusions.contains(conclusion) {
            return .refuse("\(name) concluded \(conclusion): no job failed (run it again whole, not its failed jobs)")
        }
        return .pass(nil)
    }

    func cancel(_ repository: String, _ id: Int) async -> CheckOutcome {
        switch await run(repository, id) {
        case .failure(let outcome):
            return outcome
        case .success(let (answer, name)):
            if answer["status"]?.string == "completed" {
                return .refuse("\(name) is already completed (\(answer["conclusion"]?.string ?? "")): nothing to cancel")
            }
            if answer["event"]?.string == "release" { return .refuse("\(name) is a release's run: its publishing must finish") }
            // A dispatch on the default branch is a release's proposal, or main's verify (NCH's conditions, 26 Nov 2026):
            // its signing and its draft are left to finish, whoever started it.
            if answer["event"]?.string == "workflow_dispatch" {
                let repo = await github.get("/repos/\(repository)")
                guard repo.ok, let defaultBranch = repo["default_branch"]?.string else {
                    return .fail("GitHub gave \(repository) no default branch (\(repo.status))")
                }
                if answer["head_branch"]?.string?.lowercased() == defaultBranch.lowercased() {
                    return .refuse("\(name) is a dispatch on \(defaultBranch), \(repository)'s default branch, as a release's proposal is: "
                        + "it is never cancelled by an agent")
                }
            }
            return .pass(nil)
        }
    }

    /// What a dispatch's check found: its outcome, and, as far as it read,
    /// the workflow's file and whether the branch is the default (for the
    /// audit's line: GitHubInterceptor+Dispatch).
    struct DispatchFinding: Equatable, Sendable {
        var outcome: CheckOutcome
        var workflowPath: String?
        var onDefaultBranch: Bool?
    }

    /// A dispatch on a branch of the agent's own: a workflow
    /// dispatchableWorkflows lists, active, on a branch that is there and
    /// is neither protected nor the default. On the default branch (NCH's
    /// conditions, 26 Nov 2026): a workflow mainDispatch names by its
    /// repository and exact path, active, with each of its inputs one of
    /// its values and no other, and fewer than `perHour` of the
    /// repository's let through in the last hour.
    func dispatch(_ repository: String, _ workflow: Int, branch: String, inputs: [String: String]) async -> DispatchFinding {
        // The branch by its name alone (`refs/heads/x`, `heads/x`: x), as GitHub would take it (NCH's follow-up to #417);
        // a tag never.
        let lowered = branch.lowercased()
        guard !lowered.hasPrefix("tags/"), !lowered.hasPrefix("refs/tags/"), !lowered.hasPrefix("refs/remotes/") else {
            return DispatchFinding(outcome: .refuse("a workflow is dispatched on a branch, never \(branch)"))
        }
        let name = Self.branchName(branch)
        // The repository's default branch, whatever it's called.
        let repo = await github.get("/repos/\(repository)")
        guard repo.ok, let defaultBranch = repo["default_branch"]?.string else {
            return DispatchFinding(outcome: .fail("GitHub gave \(repository) no default branch (\(repo.status))"))
        }
        let onDefault = name.lowercased() == Self.branchName(defaultBranch).lowercased()
        let answer = await github.get("/repos/\(repository)/actions/workflows/\(workflow)")
        guard answer.ok else {
            return DispatchFinding(outcome: .fail("GitHub didn't give workflow \(workflow) of \(repository) (\(answer.status))"), onDefaultBranch: onDefault)
        }
        let title = answer["name"]?.string ?? "workflow \(workflow)"
        let path = answer["path"]?.string ?? ""
        let found = { (outcome: CheckOutcome) in DispatchFinding(outcome: outcome, workflowPath: path.isEmpty ? nil : path, onDefaultBranch: onDefault) }
        let state = answer["state"]?.string ?? "unknown"
        guard onDefault else {
            if rules.protects(name, defaultBranch: defaultBranch) {
                return found(.refuse("a workflow is never dispatched on \(branch), a protected branch of \(repository): dispatch it on a branch of your own"))
            }
            // Its file, which gate.json's dispatchableWorkflows must list (NCH's review of #417).
            guard !path.isEmpty, rules.dispatches(workflowPath: path, repository: repository) else {
                return found(.refuse("\(title) (\(path.isEmpty ? "no file" : path)) isn't among the workflows an agent dispatches (gate.json's dispatchableWorkflows)"))
            }
            guard state == "active" else { return found(.refuse("\(title) is \(state): it isn't dispatched")) }
            switch await branchHead(repository, name) {
            case .failure(let outcome):
                if case .refuse = outcome { return found(.refuse("\(branch) is not a branch of \(repository)")) }
                return found(outcome)
            case .success:
                return found(.pass(nil))
            }
        }
        // On the default branch: named exactly, as this repository's (no file's name alone).
        guard !path.isEmpty, let allowed = rules.mainDispatch.inputs(repository: repository, path: path) else {
            return found(.refuse("\(title) (\(path.isEmpty ? "no file" : path)) isn't among the workflows dispatched on \(defaultBranch), "
                + "\(repository)'s default branch (gate.json's mainDispatch, each as owner/name:path): dispatch it on a branch of your own"))
        }
        guard state == "active" else { return found(.refuse("\(title) is \(state): it isn't dispatched")) }
        // Its inputs, each one of its values, and no other: what the workflow does is the list's, not the agent's.
        let wanted = allowed.keys.sorted().map { "\($0) (\(allowed[$0, default: []].joined(separator: ", ")))" }.joined(separator: "; ")
        if let other = inputs.keys.sorted().first(where: { allowed[$0] == nil }) {
            return found(.refuse("\(title) on \(defaultBranch) takes no input \(other): only \(wanted.isEmpty ? "none" : wanted)"))
        }
        for input in allowed.keys.sorted() {
            let values = allowed[input, default: []]
            guard let given = inputs[input] else {
                return found(.refuse("\(title) on \(defaultBranch) is dispatched with \(input) given: one of \(values.joined(separator: ", "))"))
            }
            guard values.contains(given) else {
                return found(.refuse("\(title)'s \(input) on \(defaultBranch) is one of \(values.joined(separator: ", ")), never another value"))
            }
        }
        // At most perHour of the repository's an hour, the gate's count.
        if let wait = throttle.take(repository, limit: rules.mainDispatch.perHour) {
            let minutes = max(1, Int((wait / 60).rounded(.up)))
            return found(.refuse("\(repository) has had \(rules.mainDispatch.perHour) dispatches on \(defaultBranch) in the last hour, "
                + "the most gate.json's mainDispatch.perHour lets through: the next in \(minutes) minute\(minutes == 1 ? "" : "s")"))
        }
        return found(.pass(nil))
    }

    /// A branch's name as GitHub resolves a short ref to one: `refs/heads/x`
    /// and `heads/x` are x.
    static func branchName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "heads/"] where ref.lowercased().hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }

    /// A branch's head ([RR6], [D6]): a refusal when it isn't a branch.
    private func branchHead(_ repository: String, _ branch: String) async -> Result<String, CheckOutcome> {
        let answer = await github.get("/repos/\(repository)/git/ref/heads/\(Self.encodedBranch(branch))")
        if answer.status == 404 { return .failure(.refuse("\(branch) is not a branch")) }
        guard answer.ok, let sha = answer["object", "sha"]?.string, GitRefName.isSHA(sha) else {
            return .failure(.fail("GitHub didn't give \(branch)'s head (\(answer.status))"))
        }
        return .success(sha)
    }
}
