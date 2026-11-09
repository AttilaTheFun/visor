#!/bin/bash
# A release's proof among its assets when the owner publishes it (ci.yml's
# release-assets job): proof.zip (AttilaTheFun/reviews' docs/PROOF_FORMAT.md,
# format 2), kept as long as the release is, past an artifact's 90 days, so
# that Reviews can compare the next release's with it however long ago it
# was, and anyone can see what was released. A release's proposal attaches it
# to the draft already (alpha); here it is checked to be of the tag's commit,
# or, where the draft has none, the `proof` artifact of the run that verified
# it (tools/ci/verified_run.sh, the release job's), or else of the newest run
# by hand that kept one, is attached, saying the tag's version.
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
# gh, in a container that may not have it (gh_ready.sh, beside this file).
# shellcheck source=tools/ci/gh_ready.sh
. "$(dirname "$0")/gh_ready.sh"
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

# The commit a proof.zip is of; empty when it is not a proof of format 2.
proved() {
    python3 -I -c 'import json, sys, zipfile
document = json.loads(zipfile.ZipFile(sys.argv[1]).read("proof.json"))
print(document.get("commit", "") if document.get("format") == 2 else "")' "$1" 2> /dev/null || true
}

# The release's own, from its proposal.
release="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" --jq .id)"
asset="$(gh api "repos/$GITHUB_REPOSITORY/releases/$release/assets?per_page=100" --jq '.[] | select(.name == "proof.zip") | .id')"
if [ -n "$asset" ]; then
    gh api -H 'Accept: application/octet-stream' "repos/$GITHUB_REPOSITORY/releases/assets/$asset" > "$work/attached.zip"
    of="$(proved "$work/attached.zip")"
    [ "$of" = "$commit" ] || { echo "::error::$tag's proof.zip is of ${of:-no commit of format 2}, not its ${commit:0:7}"; exit 1; }
    echo "$tag keeps the proof of ${commit:0:7} its proposal attached"
    exit 0
fi

# Else the run given, or the commit's runs by hand, newest first: the first
# that kept a proof.
run=""
candidates="$given"
[ -n "$candidates" ] || candidates="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$commit&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs | sort_by(.created_at) | reverse | .[].id')"
for candidate in $candidates; do
    id="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$candidate/artifacts?name=proof" \
        --jq '[.artifacts[] | select(.name == "proof" and (.expired | not))][0].id // empty')"
    [ -n "$id" ] || continue
    run="$candidate"
    gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" > "$work/artifact.zip"
    break
done
[ -n "$run" ] || { echo "::error::$tag's commit (${commit:0:7}) has no proof GitHub keeps"; exit 1; }
# The artifact is GitHub's zip around proof.zip.
unzip -q "$work/artifact.zip" proof.zip -d "$work" ||
    { echo "::error::run $run's proof is not a proof.zip of format 2: verify the commit again"; exit 1; }
of="$(proved "$work/proof.zip")"
[ "$of" = "$commit" ] || { echo "::error::run $run's proof is of ${of:-no commit of format 2}, not $tag's ${commit:0:7}"; exit 1; }
mkdir -p "$work/assets"
"$(dirname "$0")/proof_version.sh" "$work/proof.zip" "${tag#v}" "$work/assets/proof.zip"
gh release upload "$tag" "$work/assets/proof.zip" --repo "$GITHUB_REPOSITORY" --clobber
echo "Attached run $run's proof of ${commit:0:7} to $tag as proof.zip"
