#!/bin/bash
# A published release's Production builds (ci.yml's release job): the
# Apple Alphas its proposal attached (release_alphas.sh), with Visor for
# Android's APK when release-android built and signed one, promoted by
# Shireworks (sign_from_ci.sh --promote) into <dir>, with builds.json, for
# release-assets to attach.
#
# Android never holds Apple's back (New Container Helper, 2026-11-15):
# without an APK, Apple's are promoted alone, and the run's
# release-android-result job fails after release-assets has attached them.
# Re-running the run's failed jobs then promotes the APK alone: Apple's
# builds, Production on the release already (its builds.json lists them,
# of this commit), are left as they are, and builds.json is the release's
# with the APK's line in it, so that release-assets replaces only the APK
# and builds.json.
#
#   tools/ci/promote_release.sh <tag> <dir> [<android dir>]
#
# From the job's environment: GH_TOKEN, the job's; GITHUB_REPOSITORY and
# GITHUB_SHA (the tag's commit); and what sign_from_ci.sh needs (its
# `id-token: write`, the runner's SHIREWORKS_GRANT).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage="usage: tools/ci/promote_release.sh <tag> <dir> [<android dir>]"
tag="${1:?$usage}"
dir="${2:?$usage}"
android="${3:-}"
repo="${GITHUB_REPOSITORY:?}"
commit="${GITHUB_SHA:?}"
: "${GH_TOKEN:?GH_TOKEN, the job token}"
fail() { echo "promote_release: $*" >&2; exit 1; }
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$tag" --repo "$repo" --pattern builds.json --dir "$work/release" || fail "$tag has no builds.json"

# Apple's promoted already: the release's builds.json lists a Production
# .ipa or Mac .zip of this commit (a re-run, after Android's failed).
promoted="$(python3 -I - "$work/release/builds.json" "$commit" << 'PY'
import json, sys
builds = json.load(open(sys.argv[1]))
print("yes" if any(b.get("variant") == "Production" and b.get("commit") == sys.argv[2]
                   and b.get("file", "").endswith((".ipa", ".zip")) for b in builds) else "no")
PY
)"

packages=()
if [ "$promoted" = no ]; then
  "$ROOT/tools/ci/release_alphas.sh" "$tag" "$work/alphas"
  for file in "$work"/alphas/*; do packages+=("$file"); done
else
  echo "promote_release: $tag's Apple builds are Production already, left as they are"
fi
if [ -n "$android" ] && [ -d "$android" ]; then
  for file in "$android"/*.apk; do [ -f "$file" ] && packages+=("$file"); done
fi
if [ ${#packages[@]} -eq 0 ]; then
  # Apple's done, and still no APK: the release's builds.json as it is,
  # for release-assets to attach again unchanged.
  echo "promote_release: nothing to promote: no APK from release-android"
  mkdir -p "$dir"
  cp "$work/release/builds.json" "$dir/builds.json"
  exit 0
fi

"$ROOT/tools/ci/sign_from_ci.sh" --promote --app Visor --download "$dir" "${packages[@]}"

# The APK alone: its line into the release's builds.json, in place of any
# of the same name; Apple's lines (and the disk image's) kept.
if [ "$promoted" = yes ]; then
  python3 -I - "$work/release/builds.json" "$dir/builds.json" << 'PY' || fail "builds.json was not merged"
import json, sys
release, new = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
names = {b.get("file") for b in new}
merged = [b for b in release if b.get("file") not in names] + new
with open(sys.argv[2], "w") as out:
    json.dump(merged, out, indent=2)
    out.write("\n")
PY
fi
