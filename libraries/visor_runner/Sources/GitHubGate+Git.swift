import Foundation

// GitHubGate's git rules (docs/github-gate-rules.md, §3.3): fetch and clone
// pass for an allowed repository, and for any other anonymously, with no
// token (Logan, 9 Nov 2026: a public dependency's clone); a push's command list is read before any
// of its pack goes on, and the whole push is refused if any command is.
// Only branches, never main, master or (checked by the proxy against
// GitHub) the default branch; no deletes; no signed pushes. A forced update
// of an agent's own branch goes through ([G3f], Logan, 7 Nov 2026).

extension GitHubGate {
    func decideGit(_ request: GateRequest, _ segments: [String]) -> GateDecision {
        let refused = GateDecision.refuse("github.com: only a repository's git (fetch, clone, push) goes through Visor's proxy")
        guard segments.count >= 3 else { return refused }
        let name = segments[1].hasSuffix(".git") ? String(segments[1].dropLast(4)) : segments[1]
        let rest = Array(segments.dropFirst(2))
        // Outside the allowed repositories: a fetch or a clone alone, and an
        // LFS download, with no token; anything else, as for any repository
        // not allowed, refused.
        if let outside = outside(segments[0], name) {
            switch (request.method, rest) {
            case ("GET", ["info", "refs"]) where request.query == "service=git-upload-pack":
                return .anonymous(repository: outside)
            case ("POST", ["git-upload-pack"]):
                return .anonymous(repository: outside)
            case ("POST", ["info", "lfs", "objects", "batch"]):
                guard let body = request.body, GateJSON.parse(body)?.object?["operation"]?.string == "download" else { break }
                return .anonymous(repository: outside)
            default:
                break
            }
        }
        let repository: String
        switch self.repository(segments[0], name) {
        case .success(let allowed): repository = allowed
        case .failure(let refusal): return .refuse(refusal.reason)
        }
        switch (request.method, rest) {
        case ("GET", ["info", "refs"]):
            guard let query = request.query, ["service=git-upload-pack", "service=git-receive-pack"].contains(query) else { return refused }
            return .allow(repository: repository)
        case ("POST", ["git-upload-pack"]):
            return .allow(repository: repository)
        case ("POST", ["git-receive-pack"]):
            guard request.query == nil else { return refused }
            return decidePush(request.body.map(Array.init) ?? [], repository: repository)
        case ("POST", ["info", "lfs", "objects", "batch"]):
            guard let body = request.body, let operation = GateJSON.parse(body)?.object?["operation"]?.string else { return refused }
            guard operation == "download" else { return .refuse("LFS uploads aren't Visor's proxy's; downloads are") }
            return .allow(repository: repository)
        default:
            return refused
        }
    }

    /// A push, by its command list: `bytes` are the request's body as far as
    /// the list's flush (the proxy reads that much before it forwards any).
    /// git's probe, a body of a flush alone, passes.
    func decidePush(_ bytes: [UInt8], repository: String) -> GateDecision {
        guard case .list(let list, _) = GitPushCommands.read(bytes) else { return .refuse("a push's commands can't be read") }
        guard !list.capabilities.contains(where: { $0 == "push-cert" || $0.hasPrefix("push-cert=") }) else {
            return .refuse("signed pushes (push certificates) aren't Visor's proxy's")
        }
        if list.commands.isEmpty { return .allow(repository: repository) }
        var branches: [String] = []
        let zero = { (oid: String) in oid.allSatisfy { $0 == "0" } }
        for command in list.commands {
            guard command.ref.hasPrefix("refs/heads/") else {
                return .refuse("only branches are pushed (refs/heads/…), never tags or other refs: \(command.ref)")
            }
            let branch = String(command.ref.dropFirst("refs/heads/".count))
            guard GitRefName.isBranch(branch) else { return .refuse("not a branch name git would take: \(branch)") }
            guard !rules.protects(branch, defaultBranch: nil) else {
                return .refuse("\(branch) is never pushed; push a branch of your own and open a pull request")
            }
            guard !zero(command.new) else { return .refuse("\(branch) is never deleted through Visor's proxy") }
            branches.append(branch)
        }
        // The default branch is GitHub's to say: the proxy reads it.
        return rules.protectDefaultBranch ? .check(.push(repository: repository, branches: branches)) : .allow(repository: repository)
    }
}
