import Foundation

// GitHubGate's REST rules (docs/github-gate-rules.md, §2.2 and §3.1): a read
// under an allowed repository passes; a write passes only as one of gh_mcp's
// templates (W1-W15), its body one JSON object of the template's fields with
// their values' rules, and those that change state GitHub must be read for
// first go on as a check. Merging, publishing a release and deleting a ref
// are refused first, whatever else the request is (GitHubGate+Owner).

extension GitHubGate {
    func decideREST(_ request: GateRequest, _ segments: [String]) -> GateDecision {
        if let reason = Self.logansAlone(request.method, segments) { return .refuse(reason) }
        switch request.method {
        case "GET", "HEAD":
            return decideRead(segments, path: request.path)
        case "POST", "PATCH", "PUT":
            return decideWrite(request, segments)
        default:
            return .refuse("\(request.method) \(request.path) is not among the writes the agent proxy lets through")
        }
    }

    /// [P1]: a repository's own, an id's (the token's scope bounds it), and
    /// the few global reads gh makes; a repository's outside the allowed
    /// ones, anonymously, with no token.
    private func decideRead(_ segments: [String], path: String) -> GateDecision {
        if segments.first == "repos", segments.count >= 3 {
            if let outside = outside(segments[1], segments[2]) { return .anonymous(repository: outside) }
            switch repository(segments[1], segments[2]) {
            case .success(let repository): return .allow(repository: repository)
            case .failure(let refusal): return .refuse(refusal.reason)
            }
        }
        if segments.first == "repositories", segments.count >= 2, segments[1].allSatisfy(\.isNumber) { return .allow(repository: nil) }
        if segments.first == "search" { return .allow(repository: nil) }
        if segments.isEmpty || [["rate_limit"], ["meta"], ["user"], ["octocat"], ["zen"]].contains(segments) { return .allow(repository: nil) }
        return .refuse("GET \(path) is outside the repositories the agent proxy allows")
    }

    private func decideWrite(_ request: GateRequest, _ segments: [String]) -> GateDecision {
        let named = "\(request.method) \(request.path)"
        guard request.query == nil else { return .refuse("\(named) has a query string: a write's fields are in its body") }
        let body: [String: GateJSON]
        if let data = request.body, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let object = GateJSON.parse(data)?.object else { return .refuse("\(named): a write's body is one JSON object, each key once") }
            body = object
        } else {
            body = [:]
        }
        guard segments.first == "repos", segments.count >= 4 else {
            return .refuse("\(named) is not among the writes the agent proxy lets through")
        }
        let repository: String
        switch self.repository(segments[1], segments[2]) {
        case .success(let allowed): repository = allowed
        case .failure(let refusal): return .refuse(refusal.reason)
        }
        let rest = Array(segments.dropFirst(3))
        guard let template = Template.matching(request.method, rest) else {
            return .refuse("\(named) is not among the writes the agent proxy lets through")
        }
        // A release published, by its making or its edit: Logan's alone.
        if template == .draftRelease || template == .editRelease, let draft = body["draft"], draft == .bool(false) {
            return .refuse(Owner.publishing)
        }
        let extra = Set(body.keys).subtracting(template.fields)
        guard extra.isEmpty else { return .refuse("\(named) never sends \(extra.sorted().joined(separator: ", "))") }
        return template.decide(body, numbers: rest.compactMap { Int($0) }, repository: repository, gate: self)
    }

    /// One of gh_mcp's writes ([P4]): its method and path, the fields its
    /// body may have, and what its values must be.
    enum Template: CaseIterable {
        case createPull, editPull, replyToComment, review, createIssue, editIssue, comment
        case draftRelease, editRelease, updateBranch, rerun, rerunFailed, cancel, dispatch

        var method: String {
            switch self {
            case .editPull, .editIssue, .editRelease: "PATCH"
            case .updateBranch: "PUT"
            default: "POST"
            }
        }

        /// The path after `/repos/{o}/{r}`: `{n}` is all digits.
        var path: [String] {
            switch self {
            case .createPull: ["pulls"]
            case .editPull: ["pulls", "{n}"]
            case .replyToComment: ["pulls", "{n}", "comments", "{n}", "replies"]
            case .review: ["pulls", "{n}", "reviews"]
            case .createIssue: ["issues"]
            case .editIssue: ["issues", "{n}"]
            case .comment: ["issues", "{n}", "comments"]
            case .draftRelease: ["releases"]
            case .editRelease: ["releases", "{n}"]
            case .updateBranch: ["pulls", "{n}", "update-branch"]
            case .rerun: ["actions", "runs", "{n}", "rerun"]
            case .rerunFailed: ["actions", "runs", "{n}", "rerun-failed-jobs"]
            case .cancel: ["actions", "runs", "{n}", "cancel"]
            case .dispatch: ["actions", "workflows", "{n}", "dispatches"]
            }
        }

        var fields: Set<String> {
            switch self {
            case .createPull: ["title", "head", "base", "body", "draft"]
            case .editPull: ["title", "body"]
            case .replyToComment, .comment: ["body"]
            case .review: ["body", "event", "commit_id"]
            case .createIssue, .editIssue: ["title", "body", "labels"]
            case .draftRelease: ["tag_name", "target_commitish", "name", "body", "draft"]
            case .editRelease: ["name", "body", "target_commitish", "tag_name"]
            case .updateBranch: ["expected_head_sha"]
            case .rerun, .rerunFailed, .cancel: []
            case .dispatch: ["ref", "inputs", "return_run_details"]
            }
        }

        static func matching(_ method: String, _ rest: [String]) -> Template? {
            allCases.first { template in
                template.method == method && template.path.count == rest.count
                    && zip(template.path, rest).allSatisfy { wanted, given in
                        wanted == "{n}" ? (!given.isEmpty && given.allSatisfy { $0.isASCII && $0.isNumber } && Int(given) != nil) : wanted == given
                    }
            }
        }

        /// The values' rules, and for a write GitHub must be read for first,
        /// its check.
        func decide(_ body: [String: GateJSON], numbers: [Int], repository: String, gate: GitHubGate) -> GateDecision {
            let number = numbers.first ?? 0
            switch self {
            case .createPull:
                return Self.createPull(body, repository: repository)
            case .editPull:
                guard body["title"] != nil || body["body"] != nil else { return .refuse("a pull request's edit changes a title or a body: give one") }
                return .allow(repository: repository)
            case .review:
                guard body["event"]?.string == "COMMENT" else {
                    return .refuse("a review is COMMENT only; approving and requesting changes are Logan's")
                }
                return .allow(repository: repository)
            case .editIssue:
                guard body["title"] != nil || body["body"] != nil || body["labels"] != nil else {
                    return .refuse("an issue's edit changes a title, body or labels: give one")
                }
                return .allow(repository: repository)
            case .replyToComment, .createIssue, .comment:
                return .allow(repository: repository)
            case .draftRelease:
                guard body["draft"] == .bool(true) else { return .refuse(Owner.publishing) }
                return .allow(repository: repository)
            case .editRelease:
                return .check(.releaseEdit(repository: repository, release: number))
            case .updateBranch:
                guard let sha = body["expected_head_sha"]?.string, GitRefName.isSHA(sha) else {
                    return .refuse("an update names the head it expects (expected_head_sha)")
                }
                return .check(.updateBranch(repository: repository, number: number))
            case .rerun:
                return .check(.rerun(repository: repository, run: number, failedOnly: false))
            case .rerunFailed:
                return .check(.rerun(repository: repository, run: number, failedOnly: true))
            case .cancel:
                return .check(.cancel(repository: repository, run: number))
            case .dispatch:
                return Self.dispatch(body, workflow: number, repository: repository, rules: gate.rules)
            }
        }

        /// [W1], [PC1]-[PC3]: a pull request between two branches of the
        /// repository itself.
        private static func createPull(_ body: [String: GateJSON], repository: String) -> GateDecision {
            let owner = repository.split(separator: "/").first.map(String.init) ?? ""
            var branches: [String: String] = [:]
            for side in ["head", "base"] {
                guard let given = body[side]?.string else { return .refuse("a pull request names its \(side) branch") }
                var branch = given
                if let colon = given.firstIndex(of: ":") {
                    guard given[..<colon].lowercased() == owner.lowercased() else { return .refuse("\(side) is a branch of \(owner)'s: \(given)") }
                    branch = String(given[given.index(after: colon)...])
                }
                guard GitRefName.isBranch(branch) else { return .refuse("\(side) is not a branch name: \(given)") }
                branches[side] = branch
            }
            guard branches["head"] != branches["base"] else { return .refuse("head and base are the same branch: \(branches["head"] ?? "")") }
            return .allow(repository: repository)
        }

        /// [W15], [D2], [D3]: a workflow by its id, on a branch, with a few
        /// one-line inputs.
        /// A dispatch's workflow must be one gate.json's `dispatchableWorkflows`
        /// lists (none by default), on a branch that is neither protected nor
        /// the default (NCH's review of #417): a workflow run with the
        /// repository's secrets is no agent's to start otherwise.
        private static func dispatch(_ body: [String: GateJSON], workflow: Int, repository: String, rules gate: GateRules) -> GateDecision {
            let rules = gate.dispatch
            guard !gate.dispatchableWorkflows.isEmpty else {
                return .refuse("no workflow is dispatched by an agent (gate.json's dispatchableWorkflows lists none)")
            }
            guard let ref = body["ref"]?.string, !ref.isEmpty, !ref.hasPrefix("refs/"), GitRefName.isBranch(ref) else {
                return .refuse("a dispatch names a branch (ref)")
            }
            // GitHub takes `heads/main` and `tags/v1` as main and v1 (NCH's follow-up to #417): a branch is named alone.
            let lowered = ref.lowercased()
            guard !lowered.hasPrefix("heads/"), !lowered.hasPrefix("tags/"), !lowered.hasPrefix("remotes/") else {
                return .refuse("a dispatch names a branch by its name alone, never heads/… or tags/…: \(ref)")
            }
            guard ref.lowercased() != "main", !gate.protects(ref, defaultBranch: nil) else {
                return .refuse("a workflow is never dispatched on \(ref): dispatch it on a branch of your own")
            }
            if let returns = body["return_run_details"], returns.bool == nil { return .refuse("return_run_details is true or false") }
            switch body["inputs"] {
            case nil, .null?:
                break
            case .object(let inputs)?:
                guard inputs.count <= rules.maxInputs else { return .refuse("at most \(rules.maxInputs) inputs") }
                for (name, value) in inputs {
                    guard (1...64).contains(name.count), name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                        return .refuse("an input's name is letters, digits, _ and -: \(name)")
                    }
                    guard let text = value.string, text.count <= rules.maxValueLength, !text.contains(where: \.isNewline) else {
                        return .refuse("input \(name) is one line of at most \(rules.maxValueLength) characters")
                    }
                }
            default:
                return .refuse("inputs is a JSON object of strings, like {\"kind\": \"quick\"}")
            }
            return .check(.dispatch(repository: repository, workflow: workflow, branch: ref))
        }
    }
}
