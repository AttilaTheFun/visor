import Foundation

/// GitHubGate's rules, as data (MultiPass's, moved unchanged; its
/// docs/github-proxy.md, "GitHubGate's rules"): gh_mcp's guards
/// (docs/github-gate-rules.md), with what can change without a build. Default
/// deny: what these don't allow is refused. `standard` unless agentProxy's
/// `gateRules` names a gate.json, which is this as JSON, every field given:
///
///     {"repositories": ["AttilaTheFun/*"], "protectedBranches": ["main", "master"],
///      "protectDefaultBranch": true,
///      "merge": {"methods": ["squash", "merge", "rebase"],
///                "passingConclusions": ["success", "skipped", "neutral"], "codeOwners": true},
///      "rerunEvents": ["push", "pull_request", "workflow_dispatch"],
///      "dispatch": {"maxInputs": 10, "maxValueLength": 200}, "forcePushToOwnBranches": true,
///      "ownBranchPrefixes": [], "dispatchableWorkflows": []}
///
/// The last two are agent-proxy's (NCH's review of #417), and may be left
/// out: none. Merging, publishing a release and deleting a ref are refused
/// whatever it says (GitHubGate+Owner): `merge` is read by the checks a
/// re-run and a branch's update make, never to let a merge through.
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
    /// A push that may replace a branch (not a fast-forward) goes to the
    /// agent's own branches ([G3f]: Logan, 7 Nov 2026); false: to none.
    /// agent-proxy reads the push's commands, never its pack, so it can't
    /// tell a forced update from a fast-forward: every update of a branch
    /// that is there already is taken as one that may be forced. A new
    /// branch is no such update.
    public var forcePushToOwnBranches: Bool
    /// Which branches are the agent's own (`agent/`, say): none listed,
    /// every branch that isn't protected, as MultiPass had it. Each ends in
    /// `/` (NCH's review of #417: `agent` would cover
    /// `agentx`); a gate.json with one that doesn't isn't read, and one set
    /// otherwise matches nothing.
    public var ownBranchPrefixes: [String] = []
    /// The workflows an agent may dispatch, by their file (`ci.yml`, or
    /// `.github/workflows/ci.yml`); none by default (NCH's review of #417).
    /// Never on the default branch or main, whatever this lists.
    public var dispatchableWorkflows: [String] = []

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

    /// Whether `branch` is one of the agent's own: not protected, and of one
    /// of `ownBranchPrefixes` when it lists any.
    public func isOwn(_ branch: String, defaultBranch: String?) -> Bool {
        guard !protects(branch, defaultBranch: defaultBranch) else { return false }
        return ownBranchPrefixes.isEmpty || ownBranchPrefixes.contains { Self.isPrefix($0) && branch.hasPrefix($0) }
    }

    /// Whether `prefix` may name the agent's own branches: a folder's, ending
    /// in `/` (`agent/`), with something before it.
    public static func isPrefix(_ prefix: String) -> Bool { prefix.count > 1 && prefix.hasSuffix("/") && !prefix.hasPrefix("/") }

    /// Whether a workflow, by its path (`.github/workflows/ci.yml`), may be
    /// dispatched: listed by its path or its file's name.
    public func dispatches(workflowPath path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return dispatchableWorkflows.contains { $0 == path || $0 == name }
    }

    /// The repositories logan-shire-agent's token is minted for, by name
    /// (GitHub's `repositories`, NCH's review of #417): `owner`'s that the
    /// rules list; nil when they allow every one of `owner`'s (`owner/*`), so
    /// the token reaches what the installation does.
    public func tokenRepositories(owner: String?) -> [String]? {
        guard let owner = owner?.lowercased() else { return nil }
        var names: [String] = []
        for pattern in repositories {
            let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == owner else { continue }
            if parts[1] == "*" { return nil }
            names.append(parts[1])
        }
        return names.isEmpty ? nil : names
    }

    /// The permissions logan-shire-agent's token is minted with: what the
    /// gate's rules let through, no more (NCH's review of #417). Contents
    /// (pushes, drafts), pull requests and issues written; metadata, checks
    /// and statuses read. Actions written only where a rule needs it: a
    /// re-run (`rerunEvents`) or a dispatch (`dispatchableWorkflows`); a
    /// cancel alone doesn't, and GitHub refuses it with actions read. Never
    /// `workflows`: no push changes a workflow's file.
    public var tokenPermissions: [String: String] {
        ["contents": "write", "pull_requests": "write", "issues": "write", "metadata": "read", "checks": "read", "statuses": "read",
         "actions": rerunEvents.isEmpty && dispatchableWorkflows.isEmpty ? "read" : "write"]
    }

    /// The rules in the gate.json at `path`.
    public static func load(_ path: String) throws -> GateRules {
        try JSONDecoder().decode(GateRules.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// The owner of the first repository allowed (`AttilaTheFun` of
    /// `AttilaTheFun/*`): whose installation logan-shire-agent's is, when
    /// none is named.
    public var owner: String? {
        repositories.first?.split(separator: "/").first.map(String.init)
    }

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

extension GateRules {
    /// gate.json as MultiPass wrote it, agent-proxy's own fields optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try c.decode([String].self, forKey: .repositories)
        protectedBranches = try c.decode([String].self, forKey: .protectedBranches)
        protectDefaultBranch = try c.decode(Bool.self, forKey: .protectDefaultBranch)
        merge = try c.decode(Merge.self, forKey: .merge)
        rerunEvents = try c.decode([String].self, forKey: .rerunEvents)
        dispatch = try c.decode(Dispatch.self, forKey: .dispatch)
        forcePushToOwnBranches = try c.decode(Bool.self, forKey: .forcePushToOwnBranches)
        ownBranchPrefixes = try c.decodeIfPresent([String].self, forKey: .ownBranchPrefixes) ?? []
        if let wrong = ownBranchPrefixes.first(where: { !Self.isPrefix($0) }) {
            throw DecodingError.dataCorruptedError(forKey: .ownBranchPrefixes, in: c,
                                                   debugDescription: "ownBranchPrefixes' \(wrong) doesn't end in /: `agent` would cover `agentx` (say `agent/`)")
        }
        dispatchableWorkflows = try c.decodeIfPresent([String].self, forKey: .dispatchableWorkflows) ?? []
    }
}
