import Foundation

extension Toolbox {
    static let collaboration: [Tool] = [
        Tool("git_fetch", """
            Fetch an allowed GitHub repository's branches into a checkout on this Mac, as the agent's GitHub App: \
            they land in refs/remotes/<remote>/…, for rebasing onto main and for git_push's force_with_lease. \
            Nothing is checked out or merged.
            """, [
                Param("path", .string, required: true, "The checkout's absolute path (the session's folder or a folder in it)."),
                Param("remote", .string, "The remote whose repository to fetch (default origin)."),
                Param("refs", .string, "The branches to fetch, separated by spaces or commas (default all)."),
            ], readOnly: false, run: FetchTool.run),
        Tool("pr_review_comments", "A pull request's inline review comments: path, line, author, body, and which they reply to.", [
            .repo, .number,
        ], readOnly: true, run: CollaborationTools.reviewComments),
        Tool("pr_files", "The files a pull request changes, with their patches (each clipped to 4000 characters).", [
            .repo, .number,
        ], readOnly: true, run: CollaborationTools.files),
        Tool("commits", "A branch's commits, newest first.", [
            .repo,
            Param("ref", .string, "A branch, tag or SHA to start from (default the default branch)."),
            Param("path", .string, "Only commits touching this path."),
            Param("limit", .integer, "How many (1-100, default 20).", range: 1...100),
        ], readOnly: true, run: CollaborationTools.commits),
        Tool("commit_view", "A commit: its message, parents and files with their patches.", [
            .repo, Param("ref", .string, required: true, "The commit's SHA (or a branch or tag)."),
        ], readOnly: true, run: CollaborationTools.commitView),
        Tool("compare", "How head differs from base: ahead and behind, the commits and the files.", [
            .repo,
            Param("base", .string, required: true, "The branch, tag or SHA to compare against, e.g. main."),
            Param("head", .string, required: true, "The branch, tag or SHA to compare."),
        ], readOnly: true, run: CollaborationTools.compare),
        Tool("branches", "A repository's branches (100 at most), their heads and whether they are protected.", [
            .repo,
        ], readOnly: true, run: CollaborationTools.branches),
        Tool("issues_list", "A repository's issues (pull requests left out; 50 at most).", [
            .repo,
            Param("state", .string, "open (the default), closed or all.", choices: ["open", "closed", "all"]),
            Param("labels", .string, "Only those with all these labels, comma-separated."),
        ], readOnly: true, run: CollaborationTools.issues),
        Tool("issue_view", "An issue (or a pull request's conversation): its body, labels and comments.", [
            .repo, Param("number", .integer, required: true, "The issue's number.", range: 1...Int(Int32.max)),
        ], readOnly: true, run: CollaborationTools.issueView),
        Tool("pr_review_comment_reply", "Reply to an inline review comment (pr_review_comments gives its id).", [
            .repo, .number,
            Param("comment_id", .integer, required: true, "The comment's id.", range: 1...Int.max),
            Param("body", .string, required: true, "The reply (Markdown)."),
        ], readOnly: false, run: CollaborationTools.reviewCommentReply),
        Tool("pr_review", "Review a pull request with a comment. COMMENT only: approving and requesting changes are Logan's.", [
            .repo, .number, Param("body", .string, required: true, "The review (Markdown)."),
        ], readOnly: false, run: CollaborationTools.review),
        Tool("issue_create", "Open an issue.", [
            .repo,
            Param("title", .string, required: true, "Its title."),
            Param("body", .string, required: true, "Its description (Markdown).", allowsEmpty: true),
            Param("labels", .string, "Labels, comma-separated (existing ones)."),
        ], readOnly: false, run: CollaborationTools.issueCreate),
        Tool("issue_comment", "Comment on an issue.", [
            .repo, Param("number", .integer, required: true, "The issue's number.", range: 1...Int(Int32.max)),
            Param("body", .string, required: true, "The comment (Markdown)."),
        ], readOnly: false, run: CollaborationTools.issueComment),
        Tool("issue_edit", "Change an issue's title, description or labels (never its state: closing is Logan's).", [
            .repo, Param("number", .integer, required: true, "The issue's number.", range: 1...Int(Int32.max)),
            Param("title", .string, "A new title."),
            Param("body", .string, "A new description; it replaces the old.", allowsEmpty: true),
            Param("labels", .string, "Its labels, comma-separated: they replace the old ones (\"\" for none).", allowsEmpty: true),
        ], readOnly: false, run: CollaborationTools.issueEdit),
        Tool("pr_ready_for_review", "Mark a pull request ready for review, or (ready false) turn it back into a draft.", [
            .repo, .number, Param("ready", .boolean, "true (the default): ready for review; false: back to draft."),
        ], readOnly: false, run: CollaborationTools.readyForReview),
    ]
}
