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
///      "ownBranchPrefixes": [], "dispatchableWorkflows": [],
///      "mainDispatch": {"perHour": 4, "workflows": {
///          "AttilaTheFun/visor:.github/workflows/ci.yml": {"run": ["verify", "prerelease", "release"]}}},
///      "branchDispatch": {"workflows": {
///          "AttilaTheFun/visor:.github/workflows/ci.yml": {"run": ["verify"]}}}}
///
/// The last four are agent-proxy's (NCH's review of #417; mainDispatch,
/// NCH's conditions for agents' release proposals, 26 Nov 2026;
/// branchDispatch, his review of #557), and may be left out: none. The
/// standard rules have Visor's proposals on main and its verify on a
/// branch. Merging, publishing a release, cancelling a run on the default
/// branch or a branch not the agent's own, and deleting a ref or a release
/// are refused whatever it says (GitHubGate+Owner, GateChecker+Actions):
/// `merge` is read by the checks a re-run and a branch's update make,
/// never to let a merge through.
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
    /// The workflows an agent may dispatch on a branch of its own, by their
    /// file (`ci.yml`, or `.github/workflows/ci.yml`), or by one
    /// repository's (`AttilaTheFun/visor:.github/workflows/ci.yml`), with
    /// any inputs within `dispatch`'s limits, unless branchDispatch lists it
    /// with its inputs; none by default (NCH's review of #417). Never on the
    /// default branch or main: that is `mainDispatch`'s.
    public var dispatchableWorkflows: [String] = []
    /// The workflows an agent may dispatch on a repository's default branch
    /// (main): release proposals (Logan, 23 Nov 2026: agents propose
    /// releases freely, he alone publishes; NCH's five conditions).
    public var mainDispatch: MainDispatch = .off
    /// Dispatches on a branch of the agent's own, their inputs listed
    /// (NCH's review of #557).
    public var branchDispatch: BranchDispatch = .off

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

    /// Dispatches on the default branch (NCH's conditions, 26 Nov 2026):
    /// each workflow by one repository's exact path, `owner/name:path`
    /// (`AttilaTheFun/visor:.github/workflows/ci.yml`), never by its file's
    /// name alone, since what an input means is that repository's workflow's
    /// (`run: release` proposes a draft in Visor's ci.yml; another's may
    /// publish). Each has its inputs, each with the values it may take: a
    /// dispatch gives every one of them, one of its values, and nothing
    /// else. At most `perHour` of them go on for a repository in any hour,
    /// counted by the gate (DispatchThrottle).
    public struct MainDispatch: Codable, Equatable, Sendable {
        public var perHour: Int
        /// `owner/name:path` → input → its values.
        public var workflows: [String: [String: [String]]]

        public init(perHour: Int, workflows: [String: [String: [String]]]) {
            self.perHour = perHour
            self.workflows = workflows
        }

        public static let off = MainDispatch(perHour: 4, workflows: [:])

        /// Visor's ci.yml: `verify` runs the tests, `prerelease` builds and
        /// signs main's Alphas and proposes a draft pre-release, `release`
        /// verifies, then does as prerelease and proposes a draft release
        /// (docs/DEVELOPMENT.md, "CI"). Logan's Release publishes it.
        public static let visor = MainDispatch(perHour: 4, workflows: [
            "AttilaTheFun/visor:.github/workflows/ci.yml": ["run": ["verify", "prerelease", "release"]],
        ])

        /// The inputs of `repository`'s workflow at `path`, named exactly
        /// (the repository case aside, as GitHub takes it); nil when it isn't
        /// one.
        public func inputs(repository: String, path: String) -> [String: [String]]? {
            GateRules.inputs(of: workflows, repository: repository, path: path)
        }

        /// Whether any of `repository`'s workflows is one.
        public func names(repository: String) -> Bool { GateRules.names(workflows, repository: repository) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            perHour = try c.decodeIfPresent(Int.self, forKey: .perHour) ?? MainDispatch.off.perHour
            workflows = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .workflows) ?? [:]
            guard perHour >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .perHour, in: c, debugDescription: "mainDispatch's perHour is 0 or more")
            }
            try GateRules.validate(workflows, "mainDispatch", in: c, forKey: .workflows)
        }
    }

    /// Dispatches on a branch of the agent's own with their inputs listed
    /// (NCH's review of #557): each workflow as mainDispatch's are, by one
    /// repository's exact path, with its inputs and the values each may
    /// take; a dispatch gives every one of them, one of its values, and
    /// nothing else. Where one is listed here it is held to its list, even
    /// if dispatchableWorkflows lists its file too (`ci.yml`): Visor's
    /// `run: agent-image` stays off its branches whatever else gate.json
    /// says.
    public struct BranchDispatch: Codable, Equatable, Sendable {
        /// `owner/name:path` → input → its values.
        public var workflows: [String: [String: [String]]]

        public init(workflows: [String: [String: [String]]]) {
            self.workflows = workflows
        }

        public static let off = BranchDispatch(workflows: [:])

        /// Visor's ci.yml with `run: verify` alone: its tests on the branch.
        /// Never prerelease or release off main, never agent-image (its
        /// toolchain image, pushed to ghcr.io).
        public static let visor = BranchDispatch(workflows: [
            "AttilaTheFun/visor:.github/workflows/ci.yml": ["run": ["verify"]],
        ])

        public func inputs(repository: String, path: String) -> [String: [String]]? {
            GateRules.inputs(of: workflows, repository: repository, path: path)
        }

        public func names(repository: String) -> Bool { GateRules.names(workflows, repository: repository) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workflows = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .workflows) ?? [:]
            try GateRules.validate(workflows, "branchDispatch", in: c, forKey: .workflows)
        }
    }

    /// The inputs of `repository`'s workflow at `path` in `workflows` (keyed
    /// `owner/name:path`), named exactly (the repository case aside, as
    /// GitHub takes it); nil when it isn't one.
    static func inputs(of workflows: [String: [String: [String]]], repository: String, path: String) -> [String: [String]]? {
        workflows.first { key, _ in
            guard case let (named, file)? = qualified(key) else { return false }
            return named.lowercased() == repository.lowercased() && file == path
        }?.value
    }

    static func names(_ workflows: [String: [String: [String]]], repository: String) -> Bool {
        workflows.keys.contains { qualified($0)?.repository.lowercased() == repository.lowercased() }
    }

    /// mainDispatch's or branchDispatch's workflows as gate.json must give
    /// them: each `owner/name:.github/workflows/<file>`, each input named as
    /// GitHub names them, with one or more one-line values.
    static func validate<C: KeyedDecodingContainerProtocol>(_ workflows: [String: [String: [String]]], _ field: String,
                                                            in c: C, forKey key: C.Key) throws {
        for (workflow, inputs) in workflows {
            guard qualified(workflow) != nil else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription:
                    "\(field)'s \(workflow) isn't owner/name:.github/workflows/<file>: a workflow with its inputs listed is named exactly, by its repository")
            }
            for (name, values) in inputs {
                guard isInputName(name), !values.isEmpty, values.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) }) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription:
                        "\(field)'s \(workflow): input \(name) is letters, digits, _ and -, with one or more one-line values")
                }
            }
        }
    }

    /// gh_mcp's, for Logan's repositories.
    public static let standard = GateRules(
        repositories: ["AttilaTheFun/*"],
        protectedBranches: ["main", "master"],
        protectDefaultBranch: true,
        merge: Merge(methods: ["squash", "merge", "rebase"], passingConclusions: ["success", "skipped", "neutral"], codeOwners: true),
        rerunEvents: ["push", "pull_request", "workflow_dispatch"],
        dispatch: Dispatch(maxInputs: 10, maxValueLength: 200),
        forcePushToOwnBranches: true,
        // No workflow with any inputs on a branch: Visor's ci.yml with `run:
        // agent-image` on one built and pushed its toolchain image from that
        // branch (NCH's review of #557: verify alone, branchDispatch's).
        dispatchableWorkflows: [],
        mainDispatch: .visor,
        branchDispatch: .visor
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
    /// dispatched on a branch of the agent's own: listed by its path or its
    /// file's name, or by `repository`'s path.
    public func dispatches(workflowPath path: String, repository: String? = nil) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return dispatchableWorkflows.contains { entry in
            if case let (named, file)? = Self.qualified(entry) {
                return named.lowercased() == repository?.lowercased() && file == path
            }
            return entry == path || entry == name
        }
    }

    /// `owner/name:path`, split, if it is one: an allowed repository's form
    /// (`owner/name`), and a workflow's file under `.github/workflows/`.
    static func qualified(_ entry: String) -> (repository: String, path: String)? {
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let repository = String(entry[..<colon]), path = String(entry[entry.index(after: colon)...])
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, GitHubGate.isOwner(parts[0]), GitHubGate.isName(parts[1]) else { return nil }
        let prefix = ".github/workflows/"
        let file = path.dropFirst(prefix.count)
        guard path.hasPrefix(prefix), !file.isEmpty, !file.contains("/"), file.hasSuffix(".yml") || file.hasSuffix(".yaml") else { return nil }
        return (repository, path)
    }

    /// A dispatch's input's name, as GitHub's are: 1-64 letters, digits, `_`
    /// and `-`.
    static func isInputName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
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
    /// re-run (`rerunEvents`) or a dispatch (`dispatchableWorkflows`,
    /// `mainDispatch`, `branchDispatch`); a
    /// cancel alone doesn't, and GitHub refuses it with actions read. Never
    /// `workflows`: no push changes a workflow's file.
    public var tokenPermissions: [String: String] {
        ["contents": "write", "pull_requests": "write", "issues": "write", "metadata": "read", "checks": "read", "statuses": "read",
         "actions": rerunEvents.isEmpty && dispatchableWorkflows.isEmpty && mainDispatch.workflows.isEmpty && branchDispatch.workflows.isEmpty
            ? "read" : "write"]
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
    /// gate.json as MultiPass wrote it, agent-proxy's own fields optional
    /// (one from before mainDispatch and branchDispatch is read with
    /// neither).
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
        // Left out, as in a gate.json from before it: no dispatch on main.
        mainDispatch = try c.decodeIfPresent(MainDispatch.self, forKey: .mainDispatch) ?? .off
        branchDispatch = try c.decodeIfPresent(BranchDispatch.self, forKey: .branchDispatch) ?? .off
    }
}
