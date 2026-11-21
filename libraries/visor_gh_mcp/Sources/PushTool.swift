import Foundation

/// git_push: a branch of a checkout on this Mac, pushed as the agent's app.
///
/// The push is made from a bare repository of gh_mcp's own, whose objects
/// are the checkout's (objects/info/alternates), to a URL gh_mcp builds:
/// nothing of the checkout's config (url rewrites, helpers, hooks,
/// pushurls to elsewhere) takes part, and the token reaches git only as a
/// credential helper's answer for that one command (from its environment),
/// never written into any config or URL.
enum PushTool {
    static func run(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let path = arguments.string("path")!
        let force = arguments.bool("force_with_lease") ?? false
        guard path.hasPrefix("/") else { throw ToolError.invalid("path is absolute: the checkout's path on this Mac") }
        let branch = try Refs.pushableBranch(arguments.string("branch")!)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.invalid("there is no folder at \(path) on this Mac")
        }
        let git = context.services.git

        let common = try await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        guard common.succeeded, !common.output.isEmpty else {
            throw ToolError.invalid("\(path) is not a git checkout: \(Redact.line(common.errorText))")
        }
        let gitDirectory = common.output
        if try await git.run(["show-ref", "--verify", "--quiet", "refs/tags/\(branch)"], in: path).succeeded {
            throw ToolError.refused("\(branch) is a tag in \(path); tags are never pushed")
        }
        guard let sha = try await git.value(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: path) else {
            throw ToolError.invalid("\(path) has no branch \(branch)")
        }

        // The remote `git push` would use: the branch's pushRemote,
        // remote.pushDefault, the branch's remote, origin.
        var remote = "origin"
        for key in ["branch.\(branch).pushRemote", "remote.pushDefault", "branch.\(branch).remote"] {
            if let name = try await git.value(["config", "--get", key], in: path) {
                remote = name
                break
            }
        }
        guard Refs.isRemoteName(remote) else { throw ToolError.refused("\(branch)'s remote is \(remote), not a remote gh_mcp pushes to") }
        var remoteURL = try await git.value(["config", "--get", "remote.\(remote).pushurl"], in: path)
        if remoteURL == nil {
            remoteURL = try await git.value(["config", "--get", "remote.\(remote).url"], in: path)
        }
        guard let url = remoteURL else { throw ToolError.invalid("\(path) has no remote \(remote)") }
        guard let repo = RepoName(remoteURL: url) else {
            throw ToolError.refused("remote \(remote) (\(Redact.line(url, limit: 120))) is not a GitHub repository")
        }
        context.note.repo = repo.description
        guard context.rules.allows(repo) else {
            throw ToolError.refused("\(repo) is not among the repositories gh_mcp allows (\(context.rules.patterns.joined(separator: ", ")))")
        }
        let info = try await context.github.json(repo, "GET", "/repos/\(repo)")
        if let defaultBranch = info["default_branch"]?.stringValue, defaultBranch.caseInsensitiveCompare(branch) == .orderedSame {
            throw ToolError.refused("\(branch) is \(repo)'s default branch; push a branch of your own and open a pull request")
        }
        var lease: String?
        if force {
            guard let expected = try await git.value(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], in: path) else {
                throw ToolError.refused("""
                    force_with_lease leases against refs/remotes/\(remote)/\(branch), what the checkout last saw of the branch, \
                    and the checkout has none
                    """)
            }
            lease = expected
        }

        let outcome = try await push(sha: sha, branch: branch, lease: lease, repo: repo, gitDirectory: gitDirectory, context: context)

        // What `git push` itself would note: the remote-tracking branch, so
        // a later lease leases against this push.
        _ = try? await git.run(["update-ref", "refs/remotes/\(remote)/\(branch)", sha], in: path)
        return "Pushed \(branch) to \(repo) at \(sha.prefix(12)) (\(outcome))."
    }

    /// The push itself, from a scratch repository; once more with a new
    /// token if GitHub refuses the first.
    static func push(sha: String, branch: String, lease: String?, repo: RepoName, gitDirectory: String, context: ToolContext) async throws -> String {
        let git = context.services.git
        let scratch = try await makeScratch(gitDirectory: gitDirectory, context: context)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let target = context.services.remoteURL(repo)
        var arguments = credentialArguments(url: target) + ["push", "--porcelain", "--no-verify"]
        if let lease { arguments.append("--force-with-lease=refs/heads/\(branch):\(lease)") }
        arguments += [target, "\(sha):refs/heads/\(branch)"]

        var attempt = 0
        while true {
            attempt += 1
            let token = try await context.github.token(for: repo)
            let result = try await git.run(arguments, in: scratch, environment: ["GH_MCP_TOKEN": token], timeout: 600)
            let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
            let refLine = lines.first { $0.contains("\trefs/heads/") || $0.contains(":refs/heads/") }
            if result.succeeded {
                switch refLine?.first {
                case "*": return "a new branch"
                case "+": return "forced"
                case "=": return "already up to date"
                default: return "fast-forward"
                }
            }
            let errors = result.errorText
            if attempt == 1, errors.contains("Authentication failed") || errors.contains("Invalid username or token") || errors.contains("403") {
                await context.services.tokens.invalidate(agent: context.caller.agent, owner: repo.owner, token: token)
                continue
            }
            if let refLine, refLine.hasPrefix("!") {
                let reason = refLine.split(separator: "\t").last.map(String.init) ?? refLine
                var hint = ""
                if reason.contains("non-fast-forward") || reason.contains("fetch first") {
                    hint = ": the remote branch has commits the checkout's lacks; force_with_lease replaces it"
                } else if reason.contains("stale info") {
                    hint = ": the remote branch moved since the checkout last saw it; nothing was replaced"
                }
                throw ToolError.failed("GitHub refused the push of \(branch): \(Redact.line(reason))\(hint)")
            }
            let detail = errors.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? "git push failed"
            throw ToolError.failed("git push of \(branch) failed: \(Redact.line(detail))")
        }
    }
}
