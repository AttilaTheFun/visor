import Foundation

/// git_fetch: an allowed repository's branches fetched into a checkout's
/// remote-tracking refs, so an agent with no credential can rebase onto
/// main and lease its pushes.
///
/// As with git_push, the network fetch runs in a scratch repository of
/// gh_mcp's own (the checkout's objects through alternates, its refs copied
/// in so GitHub sends only what is new), the token a one-off credential
/// helper's answer. The checkout then fetches from that scratch repository
/// on disk: no token in that command's environment, its hooks off, nothing
/// written into its config.
enum FetchTool {
    static func run(_ arguments: Arguments, _ context: ToolContext) async throws -> String {
        let path = arguments.string("path")!
        let gitDirectory = try await PushTool.gitDirectory(path, context: context)
        let git = context.services.git
        let remote = arguments.string("remote") ?? "origin"
        let repo = try await PushTool.remoteRepo(remote, in: path, forPush: false, context: context)
        var branches: [String] = []
        for word in (arguments.string("refs") ?? "").split(whereSeparator: { $0 == " " || $0 == "," }) {
            var name = String(word)
            if name.hasPrefix("refs/heads/") { name.removeFirst("refs/heads/".count) }
            guard Refs.isValid(name), !name.hasPrefix("refs/"), !name.contains("*") else {
                throw ToolError.invalid("refs names branches (main, feature/x): \(word)")
            }
            branches.append(name)
        }
        let namespace = "refs/remotes/\(remote)/"
        let fromGitHub = branches.isEmpty ? ["+refs/heads/*:\(namespace)*"] : branches.map { "+refs/heads/\($0):\(namespace)\($0)" }
        let intoCheckout = branches.isEmpty ? ["+\(namespace)*:\(namespace)*"] : branches.map { "+\(namespace)\($0):\(namespace)\($0)" }

        let before = try await trackingRefs(namespace, in: path, git: git)
        let scratch = try await PushTool.makeScratch(gitDirectory: gitDirectory, context: context)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let refs = try await git.run(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/remotes", "refs/tags"], in: path)
        // Not the symbolic HEADs: copied as plain refs, the checkout would
        // write the old main through its origin/HEAD.
        let packed = refs.output.split(whereSeparator: \.isNewline).filter { !$0.hasSuffix("/HEAD") }.map { $0 + "\n" }.joined()
        try packed.write(toFile: scratch + "/packed-refs", atomically: true, encoding: .utf8)

        let url = context.services.remoteURL(repo)
        let fetch = PushTool.credentialArguments(url: url) + ["fetch", "--no-tags", "--no-write-fetch-head", url] + fromGitHub
        var attempt = 0
        while true {
            attempt += 1
            let token = try await context.github.token(for: repo)
            let result = try await git.run(fetch, in: scratch, environment: ["GH_MCP_TOKEN": token], timeout: 600)
            if result.succeeded { break }
            let errors = result.errorText
            if attempt == 1, errors.contains("Authentication failed") || errors.contains("Invalid username or token") || errors.contains("403") {
                await context.services.tokens.invalidate(agent: context.caller.agent, owner: repo.owner, token: token)
                continue
            }
            if errors.contains("couldn't find remote ref") {
                throw ToolError.failed("\(repo) has no branch \(branches.joined(separator: " or "))")
            }
            let detail = errors.split(whereSeparator: \.isNewline).last.map(String.init) ?? "git fetch failed"
            throw ToolError.failed("git fetch from \(repo) failed: \(Redact.line(detail))")
        }

        let local = try await git.run(["-c", "protocol.file.allow=always", "fetch", "--no-tags", scratch] + intoCheckout, in: path, timeout: 600)
        guard local.succeeded else {
            throw ToolError.failed("the fetched refs could not be put into \(path): \(Redact.line(local.errorText))")
        }
        let after = try await trackingRefs(namespace, in: path, git: git)
        var lines: [String] = []
        for (ref, sha) in after.sorted(by: { $0.key < $1.key }) where before[ref] != sha && !ref.hasSuffix("/HEAD") {
            let name = remote + "/" + ref.dropFirst(namespace.count)
            lines.append(before[ref].map { "\(name): \($0.prefix(12))..\(sha.prefix(12))" } ?? "\(name): new at \(sha.prefix(12))")
        }
        if lines.isEmpty { return "Fetched \(repo) into \(path): \(remote)'s branches were already up to date." }
        return "Fetched \(repo) into \(path):\n" + lines.joined(separator: "\n")
    }

    static func trackingRefs(_ namespace: String, in path: String, git: Git) async throws -> [String: String] {
        let result = try await git.run(["for-each-ref", "--format=%(objectname) %(refname)", namespace], in: path)
        var refs: [String: String] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { refs[String(parts[1])] = String(parts[0]) }
        }
        return refs
    }
}
