import Foundation

// GitHubGate's GraphQL rules (docs/github-gate-rules.md, §3.2): a query passes
// (the token's scope bounds what it reads); a mutation's every root field,
// its alias set aside and its input resolved from the variables, must be one
// gh's writes are allowed as, and every node it names is resolved to its
// repository by the proxy (GateCheck.graphQLNodes) before it goes on.
// gh pr merge's mergePullRequest goes on as the REST merge does
// (GateCheck.graphQLMerge); auto-merge is refused (Logan, 7 Nov 2026).

extension GitHubGate {
    func decideGraphQL(_ request: GateRequest) -> GateDecision {
        guard request.query == nil, let data = request.body, let body = GateJSON.parse(data)?.object else {
            return .refuse("a GraphQL request is one JSON object: query, variables, operationName")
        }
        let extra = Set(body.keys).subtracting(["query", "variables", "operationName"])
        guard extra.isEmpty else { return .refuse("a GraphQL request never sends \(extra.sorted().joined(separator: ", "))") }
        guard let text = body["query"]?.string, let document = GraphQLDocument.parse(text) else {
            return .refuse("the GraphQL document can't be read")
        }
        var variables: [String: GateJSON] = [:]
        switch body["variables"] {
        case nil, .null?: break
        case .object(let given)?: variables = given
        default: return .refuse("GraphQL's variables are an object")
        }
        let operation: GraphQLDocument.Operation
        switch body["operationName"] {
        case .string(let name)?:
            guard let named = document.operations.first(where: { $0.name == name }) else { return .refuse("the document has no operation \(name)") }
            operation = named
        case nil, .null?:
            guard document.operations.count == 1, let only = document.operations.first else {
                return .refuse("a document of several operations names the one it runs (operationName)")
            }
            operation = only
        default:
            return .refuse("operationName is a string")
        }
        switch operation.kind {
        case "query": return .allow(repository: nil)
        case "mutation": return decideMutation(operation, variables)
        default: return .refuse("GraphQL subscriptions aren't Visor's proxy's")
        }
    }

    private func decideMutation(_ operation: GraphQLDocument.Operation, _ variables: [String: GateJSON]) -> GateDecision {
        var nodes: [GateCheck.GraphQLNode] = []
        var checks: [GateCheck] = []
        for selection in operation.root {
            guard case .field(let name, let arguments, let directives) = selection else {
                return .refuse("a mutation's root is its fields, written out: no fragments")
            }
            guard !directives else { return .refuse("\(name) is run as written: no directives at a mutation's root") }
            guard Set(arguments.keys).isSubset(of: ["input"]), let given = arguments["input"]?.resolved(variables)?.object else {
                return .refuse("\(name) takes its fields in input")
            }
            switch Mutation(rawValue: name) {
            case nil:
                return .refuse(Mutation.refusal(name))
            case let mutation?:
                switch mutation.decide(given, rules: rules) {
                case .failure(let refusal): return .refuse(refusal.reason)
                case .success(let outcome):
                    nodes += outcome.nodes
                    if let check = outcome.check { checks.append(check) }
                }
            }
        }
        if let check = checks.first {
            guard operation.root.count == 1 else { return .refuse("a merge or a branch's update is a mutation of its own") }
            return .check(check)
        }
        guard !nodes.isEmpty else { return .refuse("the mutation names nothing to check its repository by") }
        return .check(.graphQLNodes(nodes))
    }

    /// The mutations gh's allowed writes are sent as.
    enum Mutation: String {
        case markPullRequestReadyForReview, convertPullRequestToDraft
        case createPullRequest, updatePullRequest
        case addComment
        case addPullRequestReview, submitPullRequestReview, addPullRequestReviewThreadReply
        case createIssue, updateIssue
        case addLabelsToLabelable, removeLabelsFromLabelable
        case updatePullRequestBranch, mergePullRequest

        struct Outcome {
            var nodes: [GateCheck.GraphQLNode]
            var check: GateCheck?
        }

        /// Its input's fields, a GitHub client's id among them.
        var fields: Set<String> {
            let named: Set<String>
            switch self {
            case .markPullRequestReadyForReview, .convertPullRequestToDraft: named = ["pullRequestId"]
            case .createPullRequest:
                named = ["repositoryId", "headRepositoryId", "baseRefName", "headRefName", "title", "body", "draft", "maintainerCanModify"]
            case .updatePullRequest: named = ["pullRequestId", "title", "body"]
            case .addComment: named = ["subjectId", "body"]
            case .addPullRequestReview: named = ["pullRequestId", "body", "event", "commitOID"]
            case .submitPullRequestReview: named = ["pullRequestId", "pullRequestReviewId", "body", "event"]
            case .addPullRequestReviewThreadReply: named = ["pullRequestReviewThreadId", "body"]
            case .createIssue: named = ["repositoryId", "title", "body", "labelIds"]
            case .updateIssue: named = ["id", "title", "body", "labelIds"]
            case .addLabelsToLabelable, .removeLabelsFromLabelable: named = ["labelableId", "labelIds"]
            case .updatePullRequestBranch: named = ["pullRequestId", "expectedHeadOid", "updateMethod"]
            case .mergePullRequest:
                named = ["pullRequestId", "mergeMethod", "commitHeadline", "commitBody", "expectedHeadOid", "authorEmail"]
            }
            return named.union(["clientMutationId"])
        }

        func decide(_ input: [String: GateJSON], rules: GateRules) -> Result<Outcome, Refusal> {
            let extra = Set(input.keys).subtracting(fields)
            guard extra.isEmpty else { return .failure(Refusal("\(rawValue) never sends \(extra.sorted().joined(separator: ", "))")) }
            func node(_ key: String, _ kinds: [String]) -> Result<GateCheck.GraphQLNode, Refusal> {
                guard let id = input[key]?.string, !id.isEmpty else { return .failure(Refusal("\(rawValue) names its \(key)")) }
                return .success(GateCheck.GraphQLNode(id: id, kinds: kinds))
            }
            func nodes(_ pairs: [(String, [String])]) -> Result<Outcome, Refusal> {
                var found: [GateCheck.GraphQLNode] = []
                for (key, kinds) in pairs {
                    switch node(key, kinds) {
                    case .success(let one): found.append(one)
                    case .failure(let refusal): return .failure(refusal)
                    }
                }
                return .success(Outcome(nodes: found, check: nil))
            }
            switch self {
            case .markPullRequestReadyForReview, .convertPullRequestToDraft, .updatePullRequest:
                return nodes([("pullRequestId", ["PullRequest"])])
            case .createPullRequest:
                if let head = input["headRepositoryId"], head != input["repositoryId"] {
                    return .failure(Refusal("a pull request is between two branches of one repository"))
                }
                guard let head = input["headRefName"]?.string, let base = input["baseRefName"]?.string else {
                    return .failure(Refusal("a pull request names its head and base branches"))
                }
                guard !head.contains(":"), GitRefName.isBranch(head) else { return .failure(Refusal("head is a branch of the repository itself: \(head)")) }
                guard GitRefName.isBranch(base) else { return .failure(Refusal("base is not a branch name: \(base)")) }
                guard head != base else { return .failure(Refusal("head and base are the same branch: \(head)")) }
                return nodes([("repositoryId", ["Repository"])])
            case .addComment:
                return nodes([("subjectId", ["Issue", "PullRequest"])])
            case .addPullRequestReview, .submitPullRequestReview:
                guard input["event"]?.string == "COMMENT" else {
                    return .failure(Refusal("a review is COMMENT only; approving and requesting changes are Logan's"))
                }
                if self == .submitPullRequestReview, input["pullRequestReviewId"] != nil {
                    return nodes([("pullRequestReviewId", ["PullRequestReview"])])
                }
                return nodes([("pullRequestId", ["PullRequest"])])
            case .addPullRequestReviewThreadReply:
                return nodes([("pullRequestReviewThreadId", ["PullRequestReviewThread"])])
            case .createIssue:
                return nodes([("repositoryId", ["Repository"])])
            case .updateIssue:
                return nodes([("id", ["Issue"])])
            case .addLabelsToLabelable, .removeLabelsFromLabelable:
                return nodes([("labelableId", ["Issue", "PullRequest"])])
            case .updatePullRequestBranch:
                guard let head = input["expectedHeadOid"]?.string, GitRefName.isSHA(head) else {
                    return .failure(Refusal("an update names the head it expects (expectedHeadOid)"))
                }
                if let method = input["updateMethod"], method != .null, method.string != "MERGE" {
                    return .failure(Refusal("a branch is updated by a merge only, never rebased"))
                }
                guard let id = input["pullRequestId"]?.string, !id.isEmpty else { return .failure(Refusal("\(rawValue) names its pullRequestId")) }
                return .success(Outcome(nodes: [], check: .graphQLUpdateBranch(pullRequestID: id)))
            case .mergePullRequest:
                let method = (input["mergeMethod"]?.string ?? "MERGE").lowercased()
                guard rules.merge.methods.contains(method) else {
                    return .failure(Refusal("a merge names its method: \(rules.merge.methods.joined(separator: ", "))"))
                }
                if method == "rebase", input["commitHeadline"] != nil || input["commitBody"] != nil {
                    return .failure(Refusal("a rebase makes no merge commit: title and message are for squash or merge"))
                }
                guard let id = input["pullRequestId"]?.string, !id.isEmpty else { return .failure(Refusal("\(rawValue) names its pullRequestId")) }
                return .success(Outcome(nodes: [], check: .graphQLMerge(pullRequestID: id, method: method)))
            }
        }

        /// Why another mutation is refused, in gh_mcp's words where it had them.
        static func refusal(_ name: String) -> String {
            switch name {
            case "enablePullRequestAutoMerge", "disablePullRequestAutoMerge", "enqueuePullRequest", "dequeuePullRequest":
                return "\(name): a pull request is merged once its checks have passed, never later unchecked (no auto-merge)"
            case "closePullRequest", "reopenPullRequest", "closeIssue", "reopenIssue":
                return "\(name): closing and reopening are Logan's"
            case let deleting where deleting.hasPrefix("delete"):
                return "\(name): nothing is deleted through Visor's proxy"
            case "createRef", "updateRef", "updateRefs", "createCommitOnBranch":
                return "\(name): branches are pushed with git, where their rules are checked"
            default:
                return "\(name) is not among the mutations Visor's proxy lets through"
            }
        }
    }
}
