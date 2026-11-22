import Foundation

/// The repositories the tools may touch: `Owner/*` or `Owner/name`, case
/// aside, as GitHub's names are.
public struct RepoRules: Sendable, Equatable {
    public let patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns
    }

    public func allows(_ repo: RepoName) -> Bool {
        patterns.contains { pattern in
            let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].caseInsensitiveCompare(repo.owner) == .orderedSame else { return false }
            return parts[1] == "*" || parts[1].caseInsensitiveCompare(repo.name) == .orderedSame
        }
    }

    /// The `repo` argument, read and checked.
    public func check(_ text: String) throws -> RepoName {
        guard let repo = RepoName(text) else {
            throw ToolError.invalid("repo is owner/name, e.g. AttilaTheFun/oss: \(text)")
        }
        guard allows(repo) else {
            throw ToolError.refused("\(repo) is not among the repositories gh_mcp allows (\(patterns.joined(separator: ", ")))")
        }
        return repo
    }
}
