import Foundation

// The Actions checks (docs/github-gate-rules.md, §2.8): a re-run only of a
// finished push, pull_request or workflow_dispatch run at its branch's head
// ([RR1]-[RR8]); a cancel only of a run still going, never a release's
// ([C1], [C2]); a dispatch only of an active workflow on a branch that is
// there ([D5], [D6]).

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
            return .pass(nil)
        }
    }

    func dispatch(_ repository: String, _ workflow: Int, branch: String) async -> CheckOutcome {
        let answer = await github.get("/repos/\(repository)/actions/workflows/\(workflow)")
        guard answer.ok else { return .fail("GitHub didn't give workflow \(workflow) of \(repository) (\(answer.status))") }
        let title = answer["name"]?.string ?? "workflow \(workflow)"
        let state = answer["state"]?.string ?? "unknown"
        guard state == "active" else { return .refuse("\(title) is \(state): it isn't dispatched") }
        switch await branchHead(repository, branch) {
        case .failure(let outcome):
            if case .refuse = outcome { return .refuse("\(branch) is not a branch of \(repository)") }
            return outcome
        case .success:
            return .pass(nil)
        }
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
