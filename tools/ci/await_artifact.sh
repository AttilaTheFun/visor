#!/bin/bash
# An artifact of this run, waited for: a proof job starts with its run, boots
# its simulator or emulator, and then waits here for the apps its build job
# uploads, rather than starting only once the build has finished.
#
#   tools/ci/await_artifact.sh <artifact> <folder> <build job>
#
# Downloads <artifact> into <folder> once this run has it. Fails at once if
# <build job> ends without success, and 40 minutes after <build job> began
# to run: a build still queued for a runner isn't counted (0.70.1's first
# release run, 25 Nov: build-apple waited 23 minutes for a Mac, and the
# proof gave up before its apps came), though never past 100 minutes, which
# leaves the proof's own 120 its time. From
# the job's environment: GH_TOKEN (actions: read), GITHUB_REPOSITORY,
# GITHUB_RUN_ID.
#
# Sparing with GitHub: the job's token shares the repository's hourly
# budget with every other job of every run (13 Nov 2026: five proof jobs
# polling every 15 s with several calls each used it up, and the release's
# draft was refused with a 403). One call a look, every 30 s; the build
# job's state every fourth look; the download once the artifact is there.
set -euo pipefail
artifact="${1:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
folder="${2:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
job="${3:?usage: tools/ci/await_artifact.sh <artifact> <folder> <build job>}"
mkdir -p "$folder"
api="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
started=$SECONDS
# When <build job> was first seen running; until then it's queued.
building=""
looks=0
deadline() {
    if [ -n "$building" ]; then echo $((building + 2400)); else echo $((started + 6000)); fi
}
while [ $SECONDS -lt "$(deadline)" ] && [ $((SECONDS - started)) -lt 6000 ]; do
    count="$(gh api "$api/artifacts?name=$artifact&per_page=1" --jq .total_count 2> /dev/null || echo 0)"
    if [ "${count:-0}" -gt 0 ]; then
        gh run download "$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY" -n "$artifact" -D "$folder" > /dev/null
        echo "await_artifact: $artifact after $((SECONDS - started)) s"
        exit 0
    fi
    looks=$((looks + 1))
    if [ $((looks % 4)) -eq 0 ]; then
        state="$(gh api "$api/jobs?per_page=100" \
            --jq ".jobs[] | select(.name == \"$job\") | .status + \" \" + (.conclusion // \"\")" 2> /dev/null || true)"
        case "$state" in
            in_progress*) [ -n "$building" ] || building=$SECONDS ;;
            "completed success" | "" | queued* | waiting* | pending*) ;;
            completed*) echo "await_artifact: $job ended ${state#completed }: no $artifact" >&2; exit 1 ;;
        esac
    fi
    sleep 30
done
echo "await_artifact: no $artifact after $(( (SECONDS - started) / 60 )) minutes${building:+ (40 of them with $job running)}" >&2
exit 1
