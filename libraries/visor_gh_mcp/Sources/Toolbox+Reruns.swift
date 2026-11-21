import Foundation

extension Toolbox {
    static let reruns: [Tool] = [
        Tool("run_rerun", """
            Run a completed workflow run's failed jobs again (or every job, failed_only false). Only pull_request, \
            push and workflow_dispatch runs from a branch of the same repository whose commit is still the head (of \
            its open pull request, or of its branch): never an old commit's, a release's or a schedule's run. Its \
            checks run again, and pr_merge waits for them to pass.
            """, [
                .repo, .runID,
                Param("failed_only", .boolean, "Only the failed (and cancelled) jobs. Default true."),
            ], readOnly: false, run: RerunTools.rerun),
        Tool("run_dispatch", """
            Run a workflow that declares workflow_dispatch, on a branch of the same repository (main too), with \
            optional inputs (a JSON object of one-line strings). Answers the run it made, with its id and the \
            commit it runs on. Its checks are the workflow's own; nothing about merging changes.
            """, [
                .repo,
                Param("workflow", .string, required: true, "The workflow's file name in .github/workflows (ci.yml), or its id."),
                Param("ref", .string, required: true, "The branch to run it on."),
                Param("inputs", .string, #"Its inputs, a JSON object of strings: {"kind": "quick"}."#),
            ], readOnly: false, run: RerunTools.dispatch),
        Tool("run_cancel", """
            Cancel a workflow run that is queued or in progress (not a release's). GitHub cancels asynchronously; \
            never a force-cancel.
            """, [
                .repo, .runID,
            ], readOnly: false, run: RerunTools.cancel),
    ]
}
