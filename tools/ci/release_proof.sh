#!/bin/bash
# A release's proof attached to its GitHub release when the owner publishes
# it (ci.yml's release-assets job): the proof of its commit that Reviews
# showed, the `proof` artifact of the run that verified it
# (tools/ci/verified_run.sh, the release job's), or else the newest run's
# by hand that kept one; its proof.json and each screen as
# proof-<screen>.png. Kept so as long as the release is, past an
# artifact's 90 days: the next release's proof is compared with these
# (tools/ci/base_proof_screens.sh), and anyone can see what was released.
#
#   tools/ci/release_proof.sh <tag> [--run <run id>]
#
#   GH_TOKEN           a token that reads the repository's Actions and
#                      writes its releases (contents: write)
#   GITHUB_REPOSITORY  owner/name (a job has it)
#
# Fails when the tag's commit has no proof GitHub still keeps, or the
# proof is of another commit.
set -euo pipefail
me="$(basename "$0")"
tag="${1:?usage: tools/ci/release_proof.sh <tag> [--run <run id>]}"
given=""
if [ $# -gt 1 ]; then
    [ "$2" = --run ] && [ -n "${3:-}" ] || { echo "usage: $me <tag> [--run <run id>]" >&2; exit 2; }
    given="$3"
fi
[ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "$me: no GH_TOKEN and GITHUB_REPOSITORY" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
commit="$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)"

# The run given, or the commit's runs by hand, newest first: the first that
# kept a proof.
run=""
candidates="$given"
[ -n "$candidates" ] || candidates="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$commit&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs | sort_by(.created_at) | reverse | .[].id')"
for candidate in $candidates; do
    id="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$candidate/artifacts?name=proof" \
        --jq '[.artifacts[] | select(.name == "proof" and (.expired | not))][0].id // empty')"
    [ -n "$id" ] || continue
    run="$candidate"
    gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" > "$work/proof.zip"
    break
done
[ -n "$run" ] || { echo "::error::$tag's commit (${commit:0:7}) has no proof GitHub keeps"; exit 1; }
mkdir -p "$work/proof" "$work/assets"
unzip -q "$work/proof.zip" 'proof.json' 'screens/*' -d "$work/proof"
proved="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("commit", ""))' "$work/proof/proof.json")"
[ "$proved" = "$commit" ] || { echo "::error::run $run's proof is of ${proved:0:7}, not $tag's ${commit:0:7}"; exit 1; }

cp "$work/proof/proof.json" "$work/assets/proof.json"
for picture in "$work/proof/screens/"*.png; do
    [ -f "$picture" ] || continue
    cp "$picture" "$work/assets/proof-$(basename "$picture")"
done
count="$(find "$work/assets" -name 'proof-*.png' | wc -l | tr -d ' ')"
[ "$count" -gt 0 ] || { echo "::error::run $run's proof has no screens"; exit 1; }
gh release upload "$tag" "$work/assets/"* --repo "$GITHUB_REPOSITORY" --clobber
echo "Attached run $run's proof of ${commit:0:7} to $tag: proof.json and $count screens"
