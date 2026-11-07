import Foundation

/// GitHubGate's rules, as data (docs/github-proxy.md, "GitHubGate's rules"):
/// gh_mcp's guards (docs/github-gate-rules.md), with what can change without a
/// build kept in the Runner's settings. Default deny: what these don't allow
/// is refused.
public struct GateRules: Codable, Equatable, Sendable {
    /// The repositories agents reach, `owner/name` with `*` for any name of an
    /// owner (`AttilaTheFun/*`), compared case-insensitively ([R2]).
    public var repositories: [String]
    /// Branches never pushed to, case-insensitively ([GP2]).
    public var protectedBranches: [String]
    /// The repository's default branch is protected too ([GP9], [G3c]).
    public var protectDefaultBranch: Bool
    public var merge: Merge
    /// The events whose runs are re-run ([RR2]).
    public var rerunEvents: [String]
    public var dispatch: Dispatch
    /// A push that replaces a branch (not a fast-forward) to a branch that
    /// isn't protected ([G3f]: Logan, 7 Nov 2026).
    public var forcePushToOwnBranches: Bool

    public struct Merge: Codable, Equatable, Sendable {
        public var methods: [String]
        /// A check run's conclusions that pass ([M11]).
        public var passingConclusions: [String]
        /// CODEOWNERS' owners must have approved the head ([M12]).
        public var codeOwners: Bool
    }

    public struct Dispatch: Codable, Equatable, Sendable {
        public var maxInputs: Int
        public var maxValueLength: Int
    }

    /// gh_mcp's, for Logan's repositories.
    public static let standard = GateRules(
        repositories: ["AttilaTheFun/*"],
        protectedBranches: ["main", "master"],
        protectDefaultBranch: true,
        merge: Merge(methods: ["squash", "merge", "rebase"], passingConclusions: ["success", "skipped", "neutral"], codeOwners: true),
        rerunEvents: ["push", "pull_request", "workflow_dispatch"],
        dispatch: Dispatch(maxInputs: 10, maxValueLength: 200),
        forcePushToOwnBranches: true
    )

    /// Whether `owner/name` is one agents reach.
    public func allows(_ repository: String) -> Bool {
        let parts = repository.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return repositories.contains { pattern in
            let wanted = pattern.lowercased().split(separator: "/", omittingEmptySubsequences: false)
            guard wanted.count == 2, wanted[0] == parts[0] else { return false }
            return wanted[1] == "*" || wanted[1] == parts[1]
        }
    }

    /// Whether a branch is never pushed to, given the repository's default.
    public func protects(_ branch: String, defaultBranch: String?) -> Bool {
        let lowered = branch.lowercased()
        if protectedBranches.contains(where: { $0.lowercased() == lowered }) { return true }
        return protectDefaultBranch && defaultBranch?.lowercased() == lowered
    }

    /// The allow-list as the refusals name it.
    var named: String { repositories.joined(separator: ", ") }
}
