/// A read the proxy makes of GitHub before a write goes on
/// (docs/github-gate-rules.md, §4.2): each names its repository and what to
/// read. GitHubGate says which; the proxy reads and decides.
public enum GateCheck: Equatable, Sendable {
    /// MultiPass's merge checks, kept with GateChecker+Merge but never asked
    /// for since merging is Logan's alone (GitHubGate+Owner):
    /// `PUT …/pulls/{n}/merge` ([M1]-[M13]): the pull request open, not a
    /// draft, into the default branch, from the same repository, clean, its
    /// head's checks passed and its code owners' approval in, and `sha` that
    /// head.
    case merge(repository: String, number: Int, sha: String, method: String)
    /// `mergePullRequest` by GraphQL, treated as the REST merge: the pull
    /// request's node resolved, the same checks, and `expectedHeadOid` set to
    /// the head read, in the variable that holds the input (gh's `$input`);
    /// one the request named already must be that head.
    case graphQLMerge(pullRequestID: String, method: String, variable: String?, expectedHeadOid: String?)
    /// `PUT …/pulls/{n}/update-branch` ([M1]-[M3]).
    case updateBranch(repository: String, number: Int)
    /// `updatePullRequestBranch` by GraphQL: the node resolved, then as above.
    case graphQLUpdateBranch(pullRequestID: String)
    /// `POST …/actions/runs/{id}/rerun[-failed-jobs]` ([RR1]-[RR8]).
    case rerun(repository: String, run: Int, failedOnly: Bool)
    /// `POST …/actions/runs/{id}/cancel` ([C1], [C2]).
    case cancel(repository: String, run: Int)
    /// `POST …/actions/workflows/{id}/dispatches` ([D5], [D6]), with its
    /// inputs: on the default branch, they are the workflow's in gate.json's
    /// `mainDispatch`.
    case dispatch(repository: String, workflow: Int, branch: String, inputs: [String: String] = [:])
    /// `PATCH …/releases/{id}` ([RL6], [RL7]): a draft, its tag sent again.
    case releaseEdit(repository: String, release: Int)
    /// A GraphQL mutation's nodes, each resolved to its repository, which
    /// must be allowed ([R2]): by id, with the kinds it may be.
    case graphQLNodes([GraphQLNode])
    /// A push's branches against the repository's default ([G3c]).
    case push(repository: String, branches: [String])
    /// `PATCH …/issues/{n}` or `…/pulls/{n}` with `state: "closed"` (Logan,
    /// 25 Nov 2026: an agent closes what it opened itself): the issue or
    /// pull request read (`GET …/issues/{n}`), its author the GitHub App's
    /// bot.
    case close(repository: String, number: Int)
    /// `closeIssue` or `closePullRequest` by GraphQL: the node read, a
    /// `kind` (Issue or PullRequest) in an allowed repository, its author
    /// the App's bot.
    case graphQLClose(id: String, kind: String)

    /// Whether it asks whose an issue or pull request is: the GitHub App's
    /// bot must be known (GateChecker's `bot`) for it to pass.
    var needsBot: Bool {
        switch self {
        case .close, .graphQLClose: true
        default: false
        }
    }

    /// A node a mutation names: its id, and what it may be.
    public struct GraphQLNode: Equatable, Sendable {
        public var id: String
        public var kinds: [String]
    }
}
