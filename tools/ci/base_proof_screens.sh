#!/bin/bash
# The screens of a revision's own proof, as CI made it, for the next proof
# to be compared with: version over version (Logan, 5 Nov 2026), the release
# before as its proof showed it, not pictures kept in the tree. From
# GitHub's API: the proof its release carries (proof.json and a
# proof-<screen>.png for each screen, attached when it was published:
# tools/ci/release_proof.sh), else the newest run by hand
# (workflow_dispatch) on its commit, of any workflow, that kept a `proof`
# artifact (90 days), as Reviews finds a commit's proof. Its screens go in
# <dir>/screens/<screen>.png, each named for its platform (ios-chat,
# android-chat, mac-chat): one of a proof from before 0.46, which had the
# iPhone's alone, unnamed, is the iPhone's. The id of the run that made the
# proof goes to standard output ("null" when its release doesn't say).
#
#   tools/ci/base_proof_screens.sh <revision> <dir>
#
#   GITHUB_TOKEN       a token that reads the repository's Actions
#   GITHUB_REPOSITORY  owner/name (a job has it)
#
# <revision> is a release's tag (v0.46.3) or a commit. Fails, saying why,
# when there is no token or GitHub keeps no such proof (none was made, or
# it is past its 90 days and its release has none).
set -euo pipefail
me="$(basename "$0")"
revision="${1:?usage: tools/ci/base_proof_screens.sh <revision> <dir>}"
out="${2:?usage: tools/ci/base_proof_screens.sh <revision> <dir>}"
[ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] \
    || { echo "$me: no GITHUB_TOKEN and GITHUB_REPOSITORY to ask GitHub with" >&2; exit 1; }
commit="$(git rev-parse --verify "$revision^{commit}")" || { echo "$me: no revision $revision" >&2; exit 1; }
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
# The token in a file this script alone reads, never on a command line.
printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$work/auth"
get() { curl -fsSL --max-time 300 -H @"$work/auth" -H 'Accept: application/vnd.github+json' "$@"; }
mkdir -p "$out/screens"

# A screen's name in a proof from before 0.46 (the iPhone's alone) made the
# iPhone's.
named() {
    case "$1" in ios-* | mac-* | android-*) printf '%s' "$1" ;; *) printf 'ios-%s' "$1" ;; esac
}

# Its release's own (a tag's), when it carries one.
if git show-ref --verify --quiet "refs/tags/$revision" && get "$api/releases/tags/$revision" > "$work/release.json" 2> /dev/null; then
    python3 -I -c 'import json, sys
for asset in json.load(open(sys.argv[1])).get("assets", []):
    name = asset["name"]
    if name == "proof.json" or (name.startswith("proof-") and name.endswith(".png")):
        print(name + "\t" + asset["url"])' "$work/release.json" > "$work/assets.tsv"
    if cut -f1 "$work/assets.tsv" | grep -qx 'proof\.json'; then
        fetched=1
        while IFS="$(printf '\t')" read -r name url; do
            target="$work/proof.json"
            if [ "$name" != proof.json ]; then
                screen="${name#proof-}"
                target="$out/screens/$(named "${screen%.png}").png"
            fi
            # An asset's bytes, by its API address: a redirect to the store,
            # which curl follows without the token.
            curl -fsSL --max-time 300 -H @"$work/auth" -H 'Accept: application/octet-stream' -o "$target" "$url" \
                || { fetched=""; break; }
        done < "$work/assets.tsv"
        if [ -n "$fetched" ]; then
            python3 -I -c 'import json, sys
run = json.load(open(sys.argv[1])).get("run")
print(run if isinstance(run, int) else "null")' "$work/proof.json"
            exit 0
        fi
        echo "$me: $revision's release has a proof GitHub didn't give: its run's, then" >&2
        rm -f "$out/screens/"*.png
    fi
fi

# Its commit's runs by hand, newest first; a run that failed elsewhere (a
# check beside the proof) still kept the proof, which is what counts.
get "$api/actions/runs?head_sha=$commit&event=workflow_dispatch&per_page=50" > "$work/runs.json" \
    || { echo "$me: GitHub didn't list $commit's runs" >&2; exit 1; }
runs="$(python3 -I -c 'import json, sys
runs = json.load(open(sys.argv[1])).get("workflow_runs", [])
for run in sorted(runs, key=lambda r: r["created_at"], reverse=True):
    print(run["id"])' "$work/runs.json")"
for run in $runs; do
    get "$api/actions/runs/$run/artifacts?name=proof" > "$work/artifacts.json" || continue
    url="$(python3 -I -c 'import json, sys
for artifact in json.load(open(sys.argv[1])).get("artifacts", []):
    if artifact["name"] == "proof" and not artifact.get("expired"):
        print(artifact["archive_download_url"]); break' "$work/artifacts.json")"
    [ -n "$url" ] || continue
    # A redirect to the blob store, which curl follows without the token.
    get -o "$work/proof.zip" "$url" || continue
    rm -rf "$work/unzipped"
    mkdir -p "$work/unzipped"
    unzip -q -o "$work/proof.zip" 'screens/*' -d "$work/unzipped" || continue
    for picture in "$work/unzipped/screens/"*.png; do
        [ -f "$picture" ] || continue
        cp "$picture" "$out/screens/$(named "$(basename "$picture" .png)").png"
    done
    echo "$run"
    exit 0
done
echo "$me: GitHub keeps no proof of $revision" >&2
exit 1
