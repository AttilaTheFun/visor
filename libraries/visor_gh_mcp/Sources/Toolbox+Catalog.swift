import Foundation

extension Toolbox {
    /// Every tool, and nothing that tags, publishes, deletes or
    /// administers (merging is pr_merge's alone, behind its guards:
    /// Merge.swift).
    static let catalog: [Tool] = [
        Tool("git_push", """
            Push a branch of a checkout on this Mac to its GitHub repository, as the agent's GitHub App. \
            The checkout is the folder the session works in (a container sees it at the same path). \
            Pushes refs/heads/<branch> only: never main, master, the repository's default branch or a tag. \
            Replaces the remote branch only with force_with_lease, against what the checkout last saw of it.
            """, [
                Param("path", .string, required: true, "The checkout's absolute path (the session's folder or a folder in it)."),
                Param("branch", .string, required: true, "The local branch to push; it is pushed under the same name."),
                Param("force_with_lease", .boolean, """
                    Replace the remote branch if it is still at refs/remotes/<remote>/<branch> in the checkout \
                    (git push --force-with-lease). Default false.
                    """),
            ], readOnly: false, run: PushTool.run),
        Tool("pr_create", "Open a pull request from a branch already pushed (git_push) into base.", [
            .repo,
            Param("head", .string, required: true, "The branch with the changes (branch, or owner:branch in the same account)."),
            Param("base", .string, required: true, "The branch to merge into, e.g. main."),
            Param("title", .string, required: true, "The pull request's title."),
            Param("body", .string, required: true, "Its description (Markdown).", allowsEmpty: true),
            Param("draft", .boolean, "Open it as a draft. Default false."),
        ], readOnly: false, run: PullRequestTools.create),
        Tool("pr_edit", "Change a pull request's title or description (nothing else: not its state, base or reviewers).", [
            .repo, .number,
            Param("title", .string, "A new title."),
            Param("body", .string, "A new description (Markdown); it replaces the old one.", allowsEmpty: true),
        ], readOnly: false, run: PullRequestTools.edit),
        Tool("pr_comment", "Comment on a pull request's conversation.", [
            .repo, .number,
            Param("body", .string, required: true, "The comment (Markdown)."),
        ], readOnly: false, run: PullRequestTools.comment),
        Tool("pr_view", "A pull request: its state, mergeability, head and base, description and reviews.", [
            .repo, .number,
        ], readOnly: true, run: PullRequestTools.view),
        Tool("pr_list", "A repository's pull requests (50 at most, newest first).", [
            .repo,
            Param("state", .string, "open (the default), closed or all.", choices: ["open", "closed", "all"]),
            Param("head", .string, "Only those from this branch (branch, or owner:branch)."),
        ], readOnly: true, run: PullRequestTools.list),
        Tool("checks", "A commit's check runs and commit statuses, and how many passed, failed or are pending.", [
            .repo,
            Param("ref", .string, required: true, "A commit SHA, branch or tag."),
        ], readOnly: true, run: ActionsTools.checks),
        Tool("runs", "A repository's GitHub Actions workflow runs, newest first.", [
            .repo,
            Param("branch", .string, "Only this branch's runs."),
            Param("event", .string, "Only runs of this event (push, pull_request, workflow_dispatch, …)."),
            Param("limit", .integer, "How many (1-50, default 10).", range: 1...50),
        ], readOnly: true, run: ActionsTools.runs),
        Tool("run_view", "A workflow run: its jobs and their conclusions (failed steps named), and its artifacts.", [
            .repo, .runID,
        ], readOnly: true, run: ActionsTools.view),
        Tool("run_log", """
            A workflow run's logs, as text: the last max_lines lines of each job's log (for a failed job, \
            the lines up to its last error), timestamps removed.
            """, [
                .repo, .runID,
                Param("job", .string, "One job: its id or its name (else every job)."),
                Param("failed_only", .boolean, "Only the jobs that failed. Default false."),
                Param("max_lines", .integer, "Lines a job at most (1-5000, default 200).", range: 1...5000),
            ], readOnly: true, run: ActionsTools.log),
        Tool("artifact_download", """
            Download a workflow run's artifact and unzip it into path: a folder that does not exist yet \
            (or is empty) inside a checkout of an allowed repository, or under /tmp.
            """, [
                .repo, .runID,
                Param("name", .string, required: true, "The artifact's name (run_view lists them)."),
                Param("path", .string, required: true, "The absolute path of the folder to unzip it into."),
            ], readOnly: false, run: ArtifactTool.run),
        Tool("release_draft", "Draft a release (a draft only: never published; publishing is a person's).", [
            .repo,
            Param("tag", .string, required: true, "The tag it will have once published (e.g. v1.2.0); not made until then."),
            Param("target", .string, required: true, "The branch or commit SHA the tag will point at."),
            Param("title", .string, required: true, "The release's title."),
            Param("body", .string, required: true, "Its notes (Markdown).", allowsEmpty: true),
        ], readOnly: false, run: ReleaseTools.draft),
        Tool("release_edit_draft", "Change a draft release's title, notes or target. Published releases are refused.", [
            .repo,
            Param("id", .integer, required: true, "The release's id (release_list shows it).", range: 1...Int.max),
            Param("title", .string, "A new title."),
            Param("body", .string, "New notes (Markdown); they replace the old.", allowsEmpty: true),
            Param("target", .string, "A new branch or commit SHA for the tag."),
        ], readOnly: false, run: ReleaseTools.editDraft),
        Tool("release_list", "A repository's releases, drafts included (30 at most, newest first).", [
            .repo,
        ], readOnly: true, run: ReleaseTools.list),
        Tool("repo_file", "Read a file from a repository on GitHub (or list a folder).", [
            .repo,
            Param("path", .string, required: true, "The file's path in the repository, e.g. README.md."),
            Param("ref", .string, "A branch, tag or commit SHA (else the default branch)."),
        ], readOnly: true, run: ReleaseTools.file),
    ]
}
