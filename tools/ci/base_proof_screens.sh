#!/bin/bash
# The screens of a commit's own proof, as CI made it, for the next proof to
# be compared with: version over version (Logan, 5 Nov 2026), the release
# before as its proof showed it, not pictures kept in the tree. From
# GitHub's API: the newest run by hand (workflow_dispatch) of this
# workflow on that commit that kept a `proof` artifact (90 days), its
# screens/ unpacked into <dir>/screens. The run's id on standard output.
#
#   tools/ci/base_proof_screens.sh <commit> <dir>
#
#   GITHUB_TOKEN       a token that reads the repository's Actions
#   GITHUB_REPOSITORY  owner/name (a job has it)
#
# Fails, saying why, when there is no token or GitHub keeps no such proof
# (none was made, or it is past its 90 days): the caller then compares with
# the pictures kept at the commit (tests/proof).
set -euo pipefail
me="$(basename "$0")"
commit="${1:?usage: tools/ci/base_proof_screens.sh <commit> <dir>}"
out="${2:?usage: tools/ci/base_proof_screens.sh <commit> <dir>}"
[ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] \
    || { echo "$me: no GITHUB_TOKEN and GITHUB_REPOSITORY to ask GitHub with" >&2; exit 1; }
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
# The token in a file this script alone reads, never on a command line.
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$work/auth"
get() { curl -fsSL --max-time 300 -H @"$work/auth" -H 'Accept: application/vnd.github+json' "$@"; }

# Its runs by hand, newest first; a run that failed elsewhere (a check
# beside the proof) still kept the proof, which is what counts.
get "$api/actions/runs?head_sha=$commit&event=workflow_dispatch&per_page=50" > "$work/runs.json" \
    || { echo "$me: GitHub didn't list $commit's runs" >&2; exit 1; }
runs="$(python3 -I - "$work/runs.json" "${GITHUB_WORKFLOW_REF:-}" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1])).get("workflow_runs", [])
# This workflow's own (its path, from the job's workflow ref), else any.
workflow = sys.argv[2].split("@", 1)[0].split("/", 2)[-1]
for run in sorted(runs, key=lambda r: r["created_at"], reverse=True):
    if not workflow or run.get("path") == workflow:
        print(run["id"])
PY
)"
for run in $runs; do
    get "$api/actions/runs/$run/artifacts?name=proof" > "$work/artifacts.json" || continue
    url="$(python3 -I -c 'import json, sys
for artifact in json.load(open(sys.argv[1])).get("artifacts", []):
    if artifact["name"] == "proof" and not artifact.get("expired"):
        print(artifact["archive_download_url"]); break' "$work/artifacts.json")"
    [ -n "$url" ] || continue
    # A redirect to the blob store, which curl follows without the token.
    get -o "$work/proof.zip" "$url" || continue
    mkdir -p "$out"
    unzip -q -o "$work/proof.zip" 'screens/*' -d "$out" || continue
    echo "$run"
    exit 0
done
echo "$me: GitHub keeps no proof of $commit" >&2
exit 1
