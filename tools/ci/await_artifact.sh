#!/bin/bash
# An artifact of this run, waited for: a proof job starts with its run, boots
# its simulator or emulator, and then waits here for the apps its build job
# uploads, rather than starting only once the build has finished.
#
#   tools/ci/await_artifact.sh <artifact> <folder> <build job>
#
# Downloads <artifact> into <folder> once this run has it. Fails at once if
# <build job> ends without success, and after 40 minutes in any case. From
# the job's environment: GH_TOKEN (actions: read), GITHUB_REPOSITORY,
# GITHUB_RUN_ID.
set -euo pipefail
artifact="${1:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
folder="${2:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
job="${3:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
mkdir -p "$folder"
started=$SECONDS
while [ $((SECONDS - started)) -lt 2400 ]; do
    if gh run download "$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY" -n "$artifact" -D "$folder" > /dev/null 2>&1; then
        echo "await_artifact: $artifact after $((SECONDS - started)) s"
        exit 0
    fi
    state="$(gh run view "$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY" --json jobs \
        --jq ".jobs[] | select(.name == \"$job\") | .status + \" \" + .conclusion" 2> /dev/null || true)"
    case "$state" in
        "completed success" | "" | queued* | in_progress* | waiting* | pending*) ;;
        completed*) echo "await_artifact: $job ended ${state#completed }: no $artifact" >&2; exit 1 ;;
    esac
    sleep 15
done
echo "await_artifact: no $artifact after 40 minutes" >&2
exit 1
