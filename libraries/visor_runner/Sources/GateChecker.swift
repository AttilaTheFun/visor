import Foundation

/// The reads the proxy makes before a write goes on (docs/github-gate-rules.md,
/// §4.2): GitHubGate says which (GateCheck), and these read GitHub with the
/// session's token and decide, in gh_mcp's order and words. The first that
/// fails is the answer.
struct GateChecker: Sendable {
    let rules: GateRules
    let github: any GitHubReading

    func run(_ check: GateCheck) async -> CheckOutcome {
        switch check {
        case .merge(let repository, let number, let sha, let method):
            return await merge(repository, number, sha: sha, method: method)
        case .graphQLMerge(let id, let method, let variable, let expected):
            return await graphQLMerge(id, method: method, variable: variable, expected: expected)
        case .updateBranch(let repository, let number):
            return await pullToUpdate(repository, number)
        case .graphQLUpdateBranch(let id):
            switch await pullRequest(node: id) {
            case .failure(let outcome): return outcome
            case .success(let (repository, number)): return await pullToUpdate(repository, number)
            }
        case .rerun(let repository, let run, let failedOnly):
            return await rerun(repository, run, failedOnly: failedOnly)
        case .cancel(let repository, let run):
            return await cancel(repository, run)
        case .dispatch(let repository, let workflow, let branch):
            return await dispatch(repository, workflow, branch: branch)
        case .releaseEdit(let repository, let release):
            return await releaseEdit(repository, release)
        case .graphQLNodes(let nodes):
            return await resolve(nodes)
        case .push(let repository, let branches):
            return await push(repository, branches)
        }
    }

    /// A path segment as GitHub's paths take it.
    static func encoded(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// A branch's path: each of its segments encoded.
    static func encodedBranch(_ branch: String) -> String {
        branch.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
    }

    static func short(_ sha: String) -> String { String(sha.prefix(12)) }

    // MARK: A draft's edit, nodes, a push

    /// [RL6], [RL7]: a draft only, and its tag sent again, since GitHub resets
    /// a draft's tag when a PATCH leaves it out.
    private func releaseEdit(_ repository: String, _ release: Int) async -> CheckOutcome {
        let answer = await github.get("/repos/\(repository)/releases/\(release)")
        guard answer.ok else { return .fail("GitHub didn't give release \(release) of \(repository) (\(answer.status))") }
        let tag = answer["tag_name"]?.string ?? ""
        guard answer["draft"]?.bool == true else {
            return .refuse("release \(release) (\(tag)) is published; Visor's proxy edits drafts only")
        }
        return .pass(tag.isEmpty ? nil : .bodyFieldIfAbsent("tag_name", .string(tag)))
    }

    /// [R2] for a mutation's nodes: each what it may be, in an allowed
    /// repository.
    private func resolve(_ nodes: [GateCheck.GraphQLNode]) async -> CheckOutcome {
        let query = """
            query($ids: [ID!]!) { nodes(ids: $ids) { __typename \
            ... on Repository { nameWithOwner } \
            ... on PullRequest { repository { nameWithOwner } } \
            ... on Issue { repository { nameWithOwner } } \
            ... on PullRequestReview { repository { nameWithOwner } } \
            ... on PullRequestReviewThread { repository { nameWithOwner } } } }
            """
        let answer = await github.graphQL(query, variables: ["ids": .array(nodes.map { .string($0.id) })])
        guard answer.ok, let found = answer["data", "nodes"]?.array, found.count == nodes.count else {
            return .fail("GitHub didn't resolve the mutation's nodes (\(answer.status))")
        }
        for (node, resolved) in zip(nodes, found) {
            guard let kind = resolved.object?["__typename"]?.string else { return .refuse("\(node.id) is no node Visor's proxy can see") }
            guard node.kinds.contains(kind) else { return .refuse("\(node.id) is a \(kind), not a \(node.kinds.joined(separator: " or "))") }
            let object = resolved.object ?? [:]
            guard let repository = object["nameWithOwner"]?.string ?? object["repository"]?.object?["nameWithOwner"]?.string else {
                return .fail("GitHub gave \(node.id) no repository")
            }
            guard rules.allows(repository) else {
                return .refuse("\(repository) is not among the repositories Visor's proxy allows (\(rules.named))")
            }
        }
        return .pass(nil)
    }

    /// [G3c]: none of the branches is the repository's default.
    private func push(_ repository: String, _ branches: [String]) async -> CheckOutcome {
        let answer = await github.get("/repos/\(repository)")
        guard answer.ok, let defaultBranch = answer["default_branch"]?.string else {
            return .fail("GitHub gave \(repository) no default branch (\(answer.status))")
        }
        if let pushed = branches.first(where: { rules.protects($0, defaultBranch: defaultBranch) }) {
            return .refuse("\(pushed) is \(repository)'s default branch; push a branch of your own and open a pull request")
        }
        return .pass(nil)
    }
}
