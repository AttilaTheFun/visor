#!/bin/bash
# The run that verified a commit (docs/CI_POLICY.md in AttilaTheFun/reviews):
# the newest of CI's runs by hand of that commit (ci.yml, workflow_dispatch,
# `run: verify` or `release`) whose `verify` job passed and that still keeps
# its `proof` artifact. The release job asks it before anything is
# promoted, and hands the run on to release-dmg, which attaches that proof
# to the release (tools/ci/release_proof.sh --run). Only curl and Python:
# the runners' image has no gh.
#
#   tools/ci/verified_run.sh <commit>
#
#   GH_TOKEN           a token that reads the repository's Actions
#   GITHUB_REPOSITORY  owner/name (a job has it)
#
# Prints the run's id; fails, saying so, when no run verified the commit.
set -euo pipefail
me="$(basename "$0")"
commit="${1:?usage: $me <commit>}"
[ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "$me: no GH_TOKEN and GITHUB_REPOSITORY" >&2; exit 1; }
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$GH_TOKEN" > "$work/auth"
get() { curl -fsSL --max-time 60 -H @"$work/auth" -H 'Accept: application/vnd.github+json' "$@"; }
# The value a short Python expression makes of a JSON file, `j` its contents.
read_json() { python3 -I -c 'import json, sys; j = json.load(open(sys.argv[1])); exec(sys.argv[2])' "$@"; }

get "$api/actions/workflows/ci.yml/runs?head_sha=$commit&event=workflow_dispatch&status=completed&per_page=50" > "$work/runs.json" \
    || { echo "::error::GitHub didn't list ${commit:0:7}'s runs"; exit 1; }
runs="$(read_json "$work/runs.json" 'for r in sorted(j.get("workflow_runs", []), key=lambda r: r["created_at"], reverse=True): print(r["id"])')"
for run in $runs; do
    # The jobs of its latest attempt: a failed verify run again that passed counts.
    get "$api/actions/runs/$run/jobs?filter=latest&per_page=100" > "$work/jobs.json" || continue
    passed="$(read_json "$work/jobs.json" 'print(sum(1 for x in j.get("jobs", []) if x["name"] == "verify" and x["conclusion"] == "success"))')"
    [ "$passed" -gt 0 ] || continue
    get "$api/actions/runs/$run/artifacts?name=proof" > "$work/artifacts.json" || continue
    kept="$(read_json "$work/artifacts.json" 'print(sum(1 for a in j.get("artifacts", []) if a["name"] == "proof" and not a.get("expired")))')"
    [ "$kept" -gt 0 ] || continue
    echo "$run"
    exit 0
done
echo "::error::${commit:0:7} has no passed verify run whose proof GitHub keeps: run CI by hand on main with run: verify"
exit 1
