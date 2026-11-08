#!/bin/bash
# A proposal's draft release (docs/CI_POLICY.md in AttilaTheFun/reviews),
# made by CI's alpha job once the commit's Alphas are published: tag
# v<version> on the commit (named, not made: a draft's tag is made only when
# Logan presses Release in Reviews), marked pre-release for a `prerelease`
# run, its notes naming the Alphas and, for a `release` run, the run that
# verified it. A run again on the same commit (the same version) brings the
# same draft up to date rather than making a second. No agent makes a draft
# or a tag: the run's token does (contents: write). Only curl and Python:
# the runners' image has no gh.
#
#   tools/ci/propose_release.sh prerelease|release <version> <published.txt>
#
# <published.txt>: tools/ci/publish_from_ci.sh's "Published …" lines.
#
#   GH_TOKEN           the job's token (contents: write)
#   GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_SERVER_URL, GITHUB_RUN_ID
#                      a job has them
set -euo pipefail
me="$(basename "$0")"
usage="usage: $me prerelease|release <version> <published.txt>"
kind="${1:?$usage}"
version="${2:?$usage}"
published="${3:?$usage}"
case "$kind" in
    prerelease) prerelease=true; title="Pre-release" ;;
    release) prerelease=false; title="Release" ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
case "$version" in
    *[!0-9.]* | "" | *.0) echo "$me: not a build's version: $version" >&2; exit 1 ;;
esac
[ -f "$published" ] || { echo "$me: no such file: $published" >&2; exit 1; }
for name in GH_TOKEN GITHUB_REPOSITORY GITHUB_SHA GITHUB_SERVER_URL GITHUB_RUN_ID; do
    [ -n "${!name:-}" ] || { echo "$me: no $name" >&2; exit 1; }
done
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
tag="v$version"
run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$GH_TOKEN" > "$work/auth"
github() { curl -fsSL --max-time 60 -H @"$work/auth" -H 'Accept: application/vnd.github+json' "$@"; }
# The releases, every page (a draft is listed only to a token that may
# write), as one JSON list. Each page in a file of its own: GitHub's JSON
# spans many lines.
releases() {
    rm -f "$work"/page-*.json
    page=1
    while :; do
        github "$api/releases?per_page=100&page=$page" > "$work/page-$page.json"
        count="$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$work/page-$page.json")"
        [ "$count" -gt 0 ] || break
        page=$((page + 1))
    done
    python3 -I -c 'import json, sys
print(json.dumps([r for p in sys.argv[1:] for r in json.load(open(p))]))' "$work"/page-*.json
}

{
    echo "$title proposed: $version, of ${GITHUB_SHA:0:7}."
    echo
    echo "Alphas, in Applications:"
    grep '^Published ' "$published" | sed 's/^Published /- /' || { echo "$me: no Alphas were published" >&2; exit 1; }
    echo
    if [ "$kind" = release ]; then
        echo "Verified by $run (its tests, and the proof as its \`proof\` artifact)."
    else
        echo "Built by $run, with no tests or proof: to release this commit, propose it as a release, which verifies it."
    fi
} > "$work/notes.md"

# A release of this tag already: a draft is brought up to date, a published
# one is never touched.
releases > "$work/releases.json"
python3 -I -c 'import json, sys
for r in json.load(open(sys.argv[1])):
    if r["tag_name"] == sys.argv[2]: print("%d\t%s" % (r["id"], "true" if r["draft"] else "false"))' \
    "$work/releases.json" "$tag" > "$work/same.tsv"
if grep -q $'\tfalse$' "$work/same.tsv"; then
    echo "::error::$tag is released already: nothing proposed"
    exit 1
fi
existing="$(head -1 "$work/same.tsv" | cut -f1)"

python3 -I -c 'import json, sys
tag, sha, name, prerelease, notes = sys.argv[1:6]
print(json.dumps({"tag_name": tag, "target_commitish": sha, "name": name,
                  "body": open(notes).read(), "draft": True,
                  "prerelease": prerelease == "true"}))' \
    "$tag" "$GITHUB_SHA" "Visor $version" "$prerelease" "$work/notes.md" > "$work/release.json"

if [ -n "$existing" ]; then
    github -X PATCH "$api/releases/$existing" --data-binary @"$work/release.json" > "$work/made.json"
    said="brought up to date"
else
    github -X POST "$api/releases" --data-binary @"$work/release.json" > "$work/made.json"
    said="made"
fi
echo "Draft $tag $said: $(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["html_url"])' "$work/made.json")"
# The draft as GitHub keeps it: its tag and kind as asked (a draft's edit
# has been seen to lose its tag).
releases > "$work/releases.json"
python3 -I -c 'import json, sys
tag, sha, prerelease = sys.argv[2], sys.argv[3], sys.argv[4] == "true"
for r in json.load(open(sys.argv[1])):
    if r["draft"] and r["tag_name"] == tag and r["target_commitish"] == sha and r["prerelease"] == prerelease: print(r["id"])' \
    "$work/releases.json" "$tag" "$GITHUB_SHA" "$prerelease" > "$work/kept"
[ -s "$work/kept" ] || { echo "::error::the draft of $tag isn't as asked: look at the repository's releases"; exit 1; }
