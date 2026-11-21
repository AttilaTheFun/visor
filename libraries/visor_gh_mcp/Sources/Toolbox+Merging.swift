import Foundation

extension Toolbox {
    static let merging: [Tool] = [
        Tool("pr_update_branch", """
            Bring a pull request's branch up to date with its base (GitHub merges the base into it), \
            if its head is still the one GitHub last showed. Only pull requests from a branch of the same repository.
            """, [
                .repo, .number,
            ], readOnly: false, run: MergeTools.updateBranch),
        Tool("pr_merge", """
            Merge a pull request once CI is green. Refused, with the reason, unless it is open, not a draft, \
            into the default branch from a branch of the same repository, GitHub's mergeable_state is clean \
            (behind: call pr_update_branch first), every check run on its head passed (statuses too where \
            readable), and it touches no path CODEOWNERS owns unless an owner approved its head. Merges exactly \
            the head checked; never bypasses GitHub's rules. Answers the merge commit.
            """, [
                .repo, .number,
                Param("method", .string, "squash (the default), merge or rebase, if the repository allows it.",
                      choices: ["squash", "merge", "rebase"]),
                Param("title", .string, "The squash (or merge) commit's title (else GitHub's)."),
                Param("message", .string, "The squash (or merge) commit's message (else GitHub's).", allowsEmpty: true),
            ], readOnly: false, run: MergeTools.merge),
    ]
}
