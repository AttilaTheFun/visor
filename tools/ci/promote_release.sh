#!/bin/bash
# A published release's Production builds (ci.yml's release job), in two
# steps around its Sign step, which alone has the signing keys
# (tools/ci/sign_builds.sh): what is to be signed, then the builds.json the
# release is given. Production comes from the tag (Logan, 15 Nov 2026): the
# Apple apps and Visor for Android are built for production from the tag's
# commit (`--config=prod`: release-apple, release-android), never the
# proposal's Alphas stamped again.
#
# Android never holds Apple's back (New Container Helper, 2026-11-15):
# without an APK, Apple's are signed alone, and the run's
# release-android-result job fails after release-assets has attached them.
# Re-running the run's failed jobs then signs the APK alone: Apple's
# builds, Production on the release already (its builds.json lists both,
# of this commit), are left as they are, and builds.json is the release's
# with the APK's line in it, so that release-assets replaces only the APK
# and builds.json.
#
#   tools/ci/promote_release.sh plan <tag> <state> <apple dir> [<android dir>]
#   tools/ci/promote_release.sh merge <state> <assets>
#
# plan: the release's builds.json saved in <state>, and <state>/packages
# written, a package a line: the Apple builds in <apple dir> (an .ipa,
# Visor.app's .zip, its Linux programs in it, and Visor Disk Utility's
# and Visor Client's .zips when release-apple built them), unless the release has them as
# Production already, and the APK in <android dir> when release-android
# built one. merge, after the Sign step signed them into <assets>: with
# nothing signed, the release's builds.json as it is; with Apple's left as
# they were, the release's builds.json with the new lines in place of any
# of the same name; else the new builds.json as it is.
#
# From the job's environment: GH_TOKEN, the job's; GITHUB_REPOSITORY and
# GITHUB_SHA (the tag's commit).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage="usage: tools/ci/promote_release.sh plan <tag> <state> <apple dir> [<android dir>] | merge <state> <assets>"
fail() { echo "promote_release: $*" >&2; exit 1; }

case "${1:-}" in
plan)
    tag="${2:?$usage}"
    state="${3:?$usage}"
    apple="${4:?$usage}"
    android="${5:-}"
    repo="${GITHUB_REPOSITORY:?}"
    commit="${GITHUB_SHA:?}"
    : "${GH_TOKEN:?GH_TOKEN, the job token}"
    # shellcheck source=tools/ci/gh_ready.sh
    . "$ROOT/tools/ci/gh_ready.sh"
    mkdir -p "$state"
    rm -f "$state/packages" "$state/builds.json" "$state/promoted"
    gh release download "$tag" --repo "$repo" --pattern builds.json --dir "$state" || fail "$tag has no builds.json"
    # Apple's signed already: the release's builds.json lists a Production
    # .ipa and a Production .zip of each Mac app built (Visor.app's, and
    # Visor Disk Utility's and Visor Client's when there are) of this commit (a re-run,
    # after Android's failed). All, not some: a first run that died
    # between them is signed again whole.
    mac_apps=(com.LoganShire.Visor)
    [ ! -f "$apple/visor_disk_utility.zip" ] || mac_apps+=(com.LoganShire.Visor.DiskUtility)
    [ ! -f "$apple/visor_macos.zip" ] || mac_apps+=(com.LoganShire.VisorClient.macOS)
    promoted="$(python3 -I - "$state/builds.json" "$commit" "${mac_apps[@]}" << 'PY'
import json, sys
builds = json.load(open(sys.argv[1]))
def production(suffix, bundle=None):
    return any(b.get("variant") == "Production" and b.get("commit") == sys.argv[2]
               and b.get("file", "").endswith(suffix) and bundle in (None, b.get("bundleID")) for b in builds)
print("yes" if production(".ipa") and all(production(".zip", bundle) for bundle in sys.argv[3:]) else "no")
PY
)"
    echo "$promoted" > "$state/promoted"
    : > "$state/packages"
    if [ "$promoted" = no ]; then
        ipas=0
        for file in "$apple"/*.ipa; do
            [ -f "$file" ] || continue
            echo "$file" >> "$state/packages"
            ipas=$((ipas + 1))
        done
        [ "$ipas" -gt 0 ] && [ -f "$apple/visor_mac.zip" ] || fail "$apple has no iPhone .ipa or no visor_mac.zip"
        echo "$apple/visor_mac.zip" >> "$state/packages"
        [ ! -f "$apple/visor_disk_utility.zip" ] || echo "$apple/visor_disk_utility.zip" >> "$state/packages"
        [ ! -f "$apple/visor_macos.zip" ] || echo "$apple/visor_macos.zip" >> "$state/packages"
    else
        echo "promote_release: $tag's Apple builds are Production already, left as they are"
    fi
    if [ -n "$android" ] && [ -d "$android" ]; then
        for file in "$android"/*.apk; do
            case "$file" in *_unsigned.apk) continue ;; esac
            [ -f "$file" ] && echo "$file" >> "$state/packages"
        done
    fi
    [ -s "$state/packages" ] || echo "promote_release: nothing to sign: Apple's are signed already, and release-android built no APK"
    sed 's/^/promote_release: to sign: /' "$state/packages"
    ;;
merge)
    state="${2:?$usage}"
    assets="${3:?$usage}"
    [ -f "$state/builds.json" ] && [ -f "$state/promoted" ] || fail "no plan in $state"
    mkdir -p "$assets"
    if [ ! -s "$state/packages" ]; then
        # Nothing signed: the release's builds.json as it is, for
        # release-assets to attach again unchanged.
        cp "$state/builds.json" "$assets/builds.json"
    elif [ "$(cat "$state/promoted")" = yes ]; then
        # The APK alone: its line into the release's builds.json, in place
        # of any of the same name; Apple's lines (and the disk image's) kept.
        [ -f "$assets/builds.json" ] || fail "nothing was signed into $assets"
        python3 -I - "$state/builds.json" "$assets/builds.json" << 'PY' || fail "builds.json was not merged"
import json, sys
release, new = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
names = {b.get("file") for b in new}
merged = [b for b in release if b.get("file") not in names] + new
with open(sys.argv[2], "w") as out:
    json.dump(merged, out, indent=2)
    out.write("\n")
PY
    else
        [ -f "$assets/builds.json" ] || fail "nothing was signed into $assets"
    fi
    ls -l "$assets"
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
