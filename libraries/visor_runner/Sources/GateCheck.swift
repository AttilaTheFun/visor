/// A read the proxy makes of GitHub before a write goes on
/// (docs/github-gate-rules.md, §4.2): each names its repository and what to
/// read. GitHubGate says which; the proxy reads and decides.
public enum GateCheck: Equatable, Sendable {
    /// `PUT …/pulls/{n}/merge` ([M1]-[M13]): the pull request open, not a
    /// draft, into the default branch, from the same repository, clean, its
    /// head's checks passed and its code owners' approval in, and `sha` that
    /// head.
    case merge(repository: String, number: Int, sha: String, method: String)
    /// `mergePullRequest` by GraphQL, treated as the REST merge: the pull
    /// request's node resolved, the same checks, and `expectedHeadOid` set to
    /// the head read.
    case graphQLMerge(pullRequestID: String, method: String)
    /// `PUT …/pulls/{n}/update-branch` ([M1]-[M3]).
    case updateBranch(repository: String, number: Int)
    /// `updatePullRequestBranch` by GraphQL: the node resolved, then as above.
    case graphQLUpdateBranch(pullRequestID: String)
    /// `POST …/actions/runs/{id}/rerun[-failed-jobs]` ([RR1]-[RR8]).
    case rerun(repository: String, run: Int, failedOnly: Bool)
    /// `POST …/actions/runs/{id}/cancel` ([C1], [C2]).
    case cancel(repository: String, run: Int)
    /// `POST …/actions/workflows/{id}/dispatches` ([D5], [D6]).
    case dispatch(repository: String, workflow: Int, branch: String)
    /// `PATCH …/releases/{id}` ([RL6], [RL7]): a draft, its tag sent again.
    case releaseEdit(repository: String, release: Int)
    /// A GraphQL mutation's nodes, each resolved to its repository, which
    /// must be allowed ([R2]): by id, with the kinds it may be.
    case graphQLNodes([GraphQLNode])
    /// A push's branches against the repository's default ([G3c]).
    case push(repository: String, branches: [String])

    /// A node a mutation names: its id, and what it may be.
    public struct GraphQLNode: Equatable, Sendable {
        public var id: String
        public var kinds: [String]
    }
}
