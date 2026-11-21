import Foundation

extension PushTool {
    /// A bare repository of gh_mcp's own whose objects are the checkout's
    /// (objects/info/alternates): pushes and fetches run there, under
    /// config gh_mcp wrote, never the checkout's.
    static func makeScratch(gitDirectory: String, context: ToolContext) async throws -> String {
        let scratch = context.services.scratch + "/gh_mcp-git-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let initialized = try await context.services.git.run(["init", "--bare", "--quiet", "--template=", scratch], in: scratch)
        guard initialized.succeeded else {
            try? FileManager.default.removeItem(atPath: scratch)
            throw ToolError.failed("git init: \(Redact.line(initialized.errorText))")
        }
        try (gitDirectory + "/objects\n").write(toFile: scratch + "/objects/info/alternates", atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: gitDirectory + "/shallow") {
            try? FileManager.default.copyItem(atPath: gitDirectory + "/shallow", toPath: scratch + "/shallow")
        }
        return scratch
    }

    /// The token as a one-off credential helper (read from GH_MCP_TOKEN in
    /// that command's environment, given only to github.com), and only
    /// `url`'s transport allowed.
    static func credentialArguments(url: String) -> [String] {
        let scheme = URL(string: url)?.scheme ?? "https"
        let helper = #"!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$GH_MCP_TOKEN"; }; f"#
        return [
            "-c", "credential.helper=", "-c", "credential.https://github.com.helper=\(helper)",
            "-c", "protocol.allow=never", "-c", "protocol.\(scheme).allow=always",
        ]
    }

    /// The remote a checkout names (its url; its pushurl first when
    /// `forPush`), as an allowed GitHub repository.
    static func remoteRepo(_ remote: String, in path: String, forPush: Bool, context: ToolContext) async throws -> RepoName {
        guard Refs.isRemoteName(remote) else { throw ToolError.invalid("not a remote's name: \(remote)") }
        let git = context.services.git
        var url = forPush ? try await git.value(["config", "--get", "remote.\(remote).pushurl"], in: path) : nil
        if url == nil { url = try await git.value(["config", "--get", "remote.\(remote).url"], in: path) }
        guard let url else { throw ToolError.invalid("\(path) has no remote \(remote)") }
        guard let repo = RepoName(remoteURL: url) else {
            throw ToolError.refused("remote \(remote) (\(Redact.line(url, limit: 120))) is not a GitHub repository")
        }
        context.note.repo = repo.description
        guard context.rules.allows(repo) else {
            throw ToolError.refused("\(repo) is not among the repositories gh_mcp allows (\(context.rules.patterns.joined(separator: ", ")))")
        }
        return repo
    }

    /// The checkout's git directory (its common one, for a linked worktree).
    static func gitDirectory(_ path: String, context: ToolContext) async throws -> String {
        guard path.hasPrefix("/") else { throw ToolError.invalid("path is absolute: the checkout's path on this Mac") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.invalid("there is no folder at \(path) on this Mac")
        }
        let common = try await context.services.git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        guard common.succeeded, !common.output.isEmpty else {
            throw ToolError.invalid("\(path) is not a git checkout: \(Redact.line(common.errorText))")
        }
        return common.output
    }
}
